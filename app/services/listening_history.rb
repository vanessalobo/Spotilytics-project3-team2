require "ostruct"

class ListeningHistory
  def initialize(spotify_user_id:)
    @spotify_user_id = spotify_user_id
  end


  def count
    return 0 if spotify_user_id.to_s.strip.empty?

    ListeningPlay
      .where(spotify_user_id: spotify_user_id)
      .distinct
      .count(:track_id)
  end

  def ingest!(plays)
    rows = Array(plays).map do |play|
      time = extract_time(play)
      next unless time

      {
        spotify_user_id: spotify_user_id,
        track_id: play.respond_to?(:id) ? play.id : play[:id],
        track_name: play.respond_to?(:name) ? play.name : play[:name],
        artists: extract_artists(play),
        album_name: safe_get(play, :album_name),
        album_image_url: safe_get(play, :album_image_url),
        preview_url: safe_get(play, :preview_url),
        spotify_url: safe_get(play, :spotify_url),
        played_at: time,
        created_at: Time.current,
        updated_at: Time.current
      }
    end.compact

    return if rows.empty?

    ListeningPlay.insert_all(rows, unique_by: :index_listening_plays_on_user_track_played_at)
  end

  def recent_entries(limit:)
    ListeningPlay
      .where(spotify_user_id: spotify_user_id)
      .order(played_at: :desc)
      .limit(limit)
      .map { |rec| to_entry(rec) }
  end

  private

  attr_reader :spotify_user_id

  def to_entry(rec)
    OpenStruct.new(
      id: rec.track_id,
      name: rec.track_name,
      artists: rec.artists,
      album_name: rec.album_name,
      album_image_url: rec.album_image_url,
      preview_url: rec.preview_url,
      spotify_url: rec.spotify_url,
      played_at: rec.played_at
    )
  end

  def extract_time(play)
    if play.respond_to?(:played_at)
      play.played_at
    else
      play[:played_at]
    end
  end

  def extract_artists(play)
    if play.respond_to?(:artists)
      play.artists
    else
      play[:artists]
    end
  end

  def safe_get(play, key)
    play.respond_to?(key) ? play.public_send(key) : play[key]
  rescue NoMethodError
    nil
  end
end
