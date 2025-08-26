# frozen_string_literal: true
class TrackBuilder
  EARTH_R = 6371.0
  MAX_HOP_HOURS = 2        # allow a gap
  MAX_HOP_DIST_KM = 500.0  # plausible 1–2h displacement

  def self.call(points)
    # group by hour (0..23 where 0 = now)
    by_h = points.group_by { |p| p[:hh].to_i }
    hours = by_h.keys.sort.reverse # 23 .. 0 (oldest -> newest is reverse; we want 23 down to 0)
    tracks = []

    prev_for_hour = {} # hour -> tracks that ended at that hour

    # seed with oldest hour
    (23).downto(0) do |hh|
      pts = (by_h[hh] || [])
      if tracks.empty?
        # initialize tracks with first available hour from the top
        pts.each { |p| tracks << { id: nil, points: [p], last_hh: hh } }
        prev_for_hour[hh] = tracks.dup
        next
      end

      # candidates are tracks whose last_hh is within MAX_HOP_HOURS of this hh+1..hh+MAX
      candidates = tracks.select { |tr| tr[:last_hh] >= hh+1 && tr[:last_hh] <= hh+MAX_HOP_HOURS }

      matched = {}
      pts.each do |p|
        best = nil
        best_d = Float::INFINITY

        candidates.each do |tr|
          a = tr[:points].last
          dt_h = (a[:hh] - p[:hh]).abs
          next if dt_h <= 0 || dt_h > MAX_HOP_HOURS
          d_km = haversine(a[:lat], a[:lon], p[:lat], p[:lon])
          next if d_km > MAX_HOP_DIST_KM
          if d_km < best_d && !matched[tr.object_id]
            best = tr; best_d = d_km
          end
        end

        if best
          best[:points] << p
          best[:last_hh] = hh
          matched[best.object_id] = true
        else
          # start a new track
          tracks << { id: nil, points: [p], last_hh: hh }
        end
      end
      prev_for_hour[hh] = tracks.select { |tr| tr[:last_hh] == hh }
    end

    # assign stable ids and drop singletons
    seq = 0
    tracks = tracks.select { |tr| tr[:points].size >= 2 }.map do |tr|
      seq += 1
      { id: "trk:#{seq}", points: tr[:points].sort_by { |p| p[:t] } }
    end
    tracks
  end

  def self.haversine(lat1,lon1,lat2,lon2)
    dlat = to_rad(lat2-lat1); dlon = to_rad(lon2-lon1)
    a = Math.sin(dlat/2)**2 + Math.cos(to_rad(lat1))*Math.cos(to_rad(lat2))*Math.sin(dlon/2)**2
    2 * EARTH_R * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
  end
  def self.to_rad(d) = d * Math::PI / 180.0
end
