# app/services/fast_track_builder.rb
class FastTrackBuilder
  EARTH_R = 6371.0
  CELL_DEG = 1.0            # ~111 km; adjust to taste
  MAX_HOP_HOURS = 2
  MAX_HOP_DIST_KM = 500.0

  def self.call(points)
    by_h = points.group_by { |p| p[:hh].to_i }
    tracks = []
    next_id = 1

    # State: for previous hours we keep the "end points" of tracks, indexed by cell
    prev_endpoints = {} # cell_key => [ {lat:,lon:,:t,:track_idx} ]

    23.downto(0) do |hh|
      pts = (by_h[hh] || [])
      idx = build_index(prev_endpoints)  # immutable snapshot
      used = {}

      pts.each do |p|
        best = nil
        best_d = Float::INFINITY

        candidate_keys(cell_key(p[:lat], p[:lon])).each do |ck|
          (idx[ck] || []).each do |ep|
            dt_h = ((ep[:t] - p[:t]).abs / 3_600_000.0)
            next if dt_h <= 0.0 || dt_h > MAX_HOP_HOURS
            d_km = haversine(ep[:lat], ep[:lon], p[:lat], p[:lon])
            next if d_km > MAX_HOP_DIST_KM
            # prefer nearest
            if d_km < best_d && !used[ep[:track_idx]]
              best = ep; best_d = d_km
            end
          end
        end

        if best
          tracks[best[:track_idx]][:points] << p
          used[best[:track_idx]] = true
        else
          tracks << { id: "trk:#{next_id}", points: [p] }
          next_id += 1
        end
      end

      # rebuild prev_endpoints from the tracks that now end at this hour
      prev_endpoints = {}
      tracks.each_with_index do |tr, i|
        last = tr[:points].last
        (prev_endpoints[cell_key(last[:lat], last[:lon])] ||= []) << { lat: last[:lat], lon: last[:lon], t: last[:t], track_idx: i }
      end
    end

    # normalize
    tracks.each { |tr| tr[:points].sort_by! { |p| p[:t] } }
    tracks.select { |tr| tr[:points].size >= 2 }
  end

  def self.cell_key(lat, lon)
    [ (lat / CELL_DEG).floor, (lon / CELL_DEG).floor ]
  end

  def self.candidate_keys(key)
    i, j = key
    [[i,j],[i+1,j],[i-1,j],[i,j+1],[i,j-1],[i+1,j+1],[i+1,j-1],[i-1,j+1],[i-1,j-1]]
  end

  def self.haversine(lat1,lon1,lat2,lon2)
    dlat = to_rad(lat2-lat1); dlon = to_rad(lon2-lon1)
    a = Math.sin(dlat/2)**2 + Math.cos(to_rad(lat1))*Math.cos(to_rad(lat2))*Math.sin(dlon/2)**2
    2 * 6371.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
  end
  def self.to_rad(d) = d * Math::PI / 180.0

  def self.build_index(prev_endpoints)
    prev_endpoints # already keyed by cell
  end
end
