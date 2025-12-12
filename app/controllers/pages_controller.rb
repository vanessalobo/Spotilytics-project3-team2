require "set"

class PagesController < ApplicationController
  before_action :require_spotify_auth!, only: %i[dashboard top_artists top_tracks view_profile clear playlist_energy]

  TOP_ARTIST_TIME_RANGES = [
    { key: "long_term", label: "Past Year" },
    { key: "medium_term", label: "Past 6 Months" },
    { key: "short_term", label: "Past 4 Weeks" }
  ].freeze

  def clear
    spotify_client.clear_user_cache()
    redirect_to home_path, notice: "Data refreshed successfully" and return

    rescue SpotifyClient::UnauthorizedError
      redirect_to home_path, alert: "You must log in with spotify to refresh your data." and return
  end

  def home
    spotify_user = session[:spotify_user]
    if spotify_user && spotify_user["id"].present?
      history = ListeningHistory.new(spotify_user_id: spotify_user["id"])
      @total_plays = history.count
    else
      @total_plays = 0
    end
  end

  def dashboard
    @top_artists = fetch_top_artists(limit: 10)
    @primary_artist = @top_artists.first

    @top_tracks = fetch_top_tracks(limit: 10)
    @primary_track = @top_tracks.first

    spotify_user = session[:spotify_user]
    if spotify_user && spotify_user["id"].present?
      journey          = TrackJourney.new(spotify_user_id: spotify_user["id"])
      @tracks_by_badge = journey.grouped_by_badge || {}
    else
      @tracks_by_badge = {}
    end

    build_genre_chart!(@top_artists)

    @followed_artists = fetch_followed_artists(limit: 20)

    @new_releases = fetch_new_releases(limit: 2)

  rescue SpotifyClient::UnauthorizedError
    redirect_to home_path,
                alert: "You must log in with spotify to access the dashboard." and return
  rescue SpotifyClient::Error => e
    flash.now[:alert] = "We were unable to load your Spotify data right now. Please try again later."
    @top_artists      = []
    @primary_artist   = nil
    @top_tracks       = []
    @primary_track    = nil
    @genre_chart      = nil
    @followed_artists = []
    @new_releases     = []
    @tracks_by_badge  = {}
  end

  def track_journey
    spotify_user = session[:spotify_user]
    unless spotify_user && spotify_user["id"].present?
      redirect_to home_path, alert: "You must log in with Spotify to see your Track Journey."
      return
    end

    spotify_user_id = spotify_user["id"]
    journey         = TrackJourney.new(spotify_user_id: spotify_user_id)

    @time_ranges     = journey.time_ranges
    @tracks_by_badge = journey.grouped_by_badge(max_per_badge: 3) || {}

    @available_badges = @tracks_by_badge.keys.map(&:to_s)

    requested = params[:selected_badge].to_s.presence
    if requested && @available_badges.include?(requested)
      @selected_badge = requested.to_sym
    else
      @selected_badge = @tracks_by_badge.keys.first
    end
  end

  def view_profile
    @profile=fetch_profile()

  rescue SpotifyClient::UnauthorizedError
    Rails.logger.warn "Unauthorized dashboard access"
    redirect_to home_path, alert: "You must log in with spotify to view your profile." and return
  rescue SpotifyClient::Error => e
    Rails.logger.warn "Failed to fetch Spotify data for dashboard: #{e.message}"
    flash.now[:alert] = "We were unable to load your Spotify data right now. Please try again later."

    @profile = nil
  end

  def mood_analysis
    spotify_user = session[:spotify_user]
    return redirect_to(home_path, alert: "Log in with Spotify first.") unless spotify_user

    client = SpotifyClient.new(session: session)

    top_tracks = client.top_tracks_1(limit: 10)

    track_id = params[:id]
    @track = top_tracks.find { |t| t.id == track_id }

    Rails.logger.info "[MoodAnalysis] Analyzing track ID #{track_id}"
    Rails.logger.info "[MoodAnalysis] Found tracks: #{top_tracks.size}"

    if @track.nil?
      return redirect_to mood_explorer_path,
        alert: "Track not found in your top 10 tracks."
    end

    features = ReccoBeatsClient.fetch_audio_features([ track_id ])
    @features = features.first

    @mood = MoodExplorerService.detect_single(@features)

  rescue => e
    Rails.logger.error "[MoodAnalysis] #{e.message}"
    redirect_to mood_explorer_path, alert: "Could not load mood analysis."
  end

  def mood_explorer
    spotify_user = session[:spotify_user]
    return redirect_to(home_path, alert: "Log in with Spotify first.") unless spotify_user

    client = SpotifyClient.new(session: session)

    @top_tracks = client.top_tracks_1(limit: 10)

    spotify_ids = @top_tracks.map(&:id)
    features = ReccoBeatsClient.fetch_audio_features(spotify_ids) || []

    @clusters = MoodExplorerService.new(@top_tracks, features).clustered
    Rails.logger.info "[MoodExplorer] Loaded #{spotify_ids.size}, features #{features.size}, top tracks #{@top_tracks.size} into #{@clusters.keys.size} mood clusters."

  rescue => e
    Rails.logger.error "[MoodExplorer] Error: #{e}"
    redirect_to dashboard_path, alert: "Could not load mood insights."
  end

  def playlist_energy
    @playlist_id = params[:id].to_s.strip
    if @playlist_id.blank?
      redirect_to dashboard_path, alert: "Please provide a playlist ID." and return
    end

    service = PlaylistEnergyService.new(client: spotify_client)
    @points = service.energy_profile(playlist_id: @playlist_id)
    @labels = @points.map { |p| p[:position] }
    @energies = @points.map { |p| p[:energy] }

    if @points.empty?
      flash.now[:alert] = "No tracks found for that playlist."
    end
  rescue SpotifyClient::UnauthorizedError
    redirect_to home_path, alert: "You must log in with spotify to view playlist energy." and return
  rescue SpotifyClient::Error => e
    Rails.logger.warn "Failed to load playlist energy: #{e.message}"
    flash.now[:alert] = "We couldn't load that playlist right now."
    @points = []
    @labels = []
    @energies = []
  end

  def top_artists
    @time_ranges = TOP_ARTIST_TIME_RANGES
    @top_artists_by_range = {}
    @limits = {}

    collected_ids = []

    @time_ranges.each do |range|
      key        = range[:key]
      param_name = "limit_#{key}"
      limit      = normalize_limit(params[param_name])

      @limits[key] = limit
      artists = fetch_top_artists(limit: limit, time_range: key)
      @top_artists_by_range[key] = artists
      collected_ids.concat(extract_artist_ids(artists))
    end

    unique_ids = collected_ids.uniq

    @followed_artist_ids =
      if unique_ids.any?
        spotify_client.followed_artist_ids(unique_ids)
      else
        Set.new
      end
  rescue SpotifyClient::UnauthorizedError
    redirect_to home_path, alert: "You must log in with spotify to view your top artists." and return
  rescue SpotifyClient::Error => e
    if insufficient_scope?(e)
      reset_spotify_session!
      redirect_to login_path, alert: "Spotify now needs permission to manage your follows. Please sign in again."
    else
      Rails.logger.warn "Failed to fetch Spotify top artists: #{e.message}"
      flash.now[:alert] = "We were unable to load your top artists from Spotify. Please try again later."
      @top_artists_by_range = TOP_ARTIST_TIME_RANGES.each_with_object({}) { |range, acc| acc[range[:key]] = [] }
      @limits = TOP_ARTIST_TIME_RANGES.to_h { |range| [ range[:key], 10 ] }
      @followed_artist_ids = Set.new
      @time_ranges = TOP_ARTIST_TIME_RANGES
    end
  end

  def top_tracks
    limit = normalize_limit(params[:limit])
    @top_tracks = fetch_top_tracks(limit: limit)
  rescue SpotifyClient::UnauthorizedError
    redirect_to home_path, alert: "You must log in with spotify to view your top tracks." and return
  rescue SpotifyClient::Error => e
    Rails.logger.warn "Failed to fetch Spotify top tracks: #{e.message}"
    flash.now[:alert] = "We were unable to load your top tracks from Spotify. Please try again later."
    @top_tracks = []
  end

  private

  def spotify_client
    @spotify_client ||= SpotifyClient.new(session: session)
  end

  def fetch_profile
    spotify_client.profile()
  end

  def fetch_new_releases(limit:)
    spotify_client.new_releases(limit: limit)
  end

  def fetch_top_artists(limit:, time_range: "long_term")
    spotify_client.top_artists(limit: limit, time_range: time_range)
  end

  def fetch_top_tracks(limit:)
    spotify_client.top_tracks(limit: limit, time_range: "long_term")
  end

  def fetch_followed_artists(limit:)
    spotify_client.followed_artists(limit: limit)
  end

  # Accept only 10, 25, 50; default to 10
  def normalize_limit(value)
    v = value.to_i
    [ 10, 25, 50 ].include?(v) ? v : 10
  end

  def build_genre_chart!(artists)
    counts = Hash.new(0)

    Array(artists).each do |a|
      genres = a.respond_to?(:genres) ? a.genres : Array(a["genres"])
      next if genres.blank?
      genres.each do |g|
        g = g.to_s.strip.downcase
        next if g.empty?
        counts[g] += 1         # count artists per genre
      end
    end

    if counts.empty?
      @genre_chart = nil
      return
    end

    sorted = counts.sort_by { |(_, c)| -c }
    top_n = 8
    top   = sorted.first(top_n)
    other = sorted.drop(top_n).sum { |(_, c)| c }

    labels = top.map { |(g, _)| g.split.map(&:capitalize).join(" ") }
    data   = top.map(&:last)
    if other > 0
      labels << "Other"
      data   << other
    end

    @genre_chart = {
      labels: labels,
      datasets: [
        {
          label: "Top Artist Genres",
          data: data
        }
      ]
    }
  end

  def extract_artist_ids(artists)
    Array(artists).map { |artist| artist_identifier(artist) }.compact
  end

  def artist_identifier(artist)
    if artist.respond_to?(:id)
      artist.id
    elsif artist.respond_to?(:[])
      artist["id"] || artist[:id]
    end
  end

  def insufficient_scope?(error)
    error.message.to_s.downcase.include?("insufficient client scope")
  end

  def reset_spotify_session!
    session.delete(:spotify_token)
    session.delete(:spotify_refresh_token)
    session.delete(:spotify_expires_at)
  end
end
