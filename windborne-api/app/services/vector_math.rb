class VectorMath
    def self.drift(track)
        a, b = track[:points][-2], track[:points][-1]
        d_km = TrackBuilder.haversine(a[:lat], a[:lon], b[:lat], b[:lon])
        dt_h = [(b[:t] - a[:t]) / 3_600_000.0, 1e-6].max
        speed = d_km / dt_h
        heading = bearing(a[:lat], a[:lon], b[:lat], b[:lon])
        { speedKmh: speed, headingDeg: heading }
    end


    def self.bearing(lat1, lon1, lat2, lon2)
        y = Math.sin(to_rad(lon2 - lon1)) * Math.cos(to_rad(lat2))
        x = Math.cos(to_rad(lat1))*Math.sin(to_rad(lat2)) - Math.sin(to_rad(lat1))*Math.cos(to_rad(lat2))*Math.cos(to_rad(lon2 - lon1))
        ( (Math.atan2(y, x) * 180 / Math::PI) + 360 ) % 360
    end


    def self.components(heading_deg, wind_from_deg, wind_speed)
        motion = (wind_from_deg + 180) % 360
        delta = ((heading_deg - motion + 540) % 360) - 180
        tail = wind_speed * Math.cos(to_rad(delta))
        cross = wind_speed * Math.sin(to_rad(delta))
        { deltaDeg: delta.abs, tailwind: tail, crosswind: cross }
    end


    def self.to_rad(d) = d * Math::PI / 180.0
end