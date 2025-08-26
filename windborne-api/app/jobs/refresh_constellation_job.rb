class RefreshConstellationJob
    include Sidekiq::Job
    def perform
        points = WindborneFetcher.call
        tracks = TrackBuilder.call(points)
        enriched = tracks.map do |tr|
        last = tr[:points].last
    begin meteo = OpenMeteoClient.at(last[:lat], last[:lon], Time.at(last[:t]/1000)) rescue nil end
        drift = VectorMath.drift(tr)
        comp = meteo ? VectorMath.components(drift[:headingDeg], meteo[:winddirection], meteo[:windspeed]) : nil
        { id: tr[:id], last: last, drift: drift, meteo: meteo, comp: comp, trail: tr[:points].map { |p| { lat: p[:lat], lon: p[:lon], t: p[:t] } } }
    end
        insights = { fastest: enriched.sort_by { |e| -e.dig(:drift, :speedKmh).to_f }.first(5), bestTail: enriched.select { |e| e[:comp] }.sort_by { |e| -e.dig(:comp, :tailwind).to_f }.first(5) }
        payload = { updatedAt: Time.now.utc.iso8601, count: enriched.size, balloons: enriched, insights: insights }
        $redis.setex("constellation:v1", 120, Oj.dump(payload))
    end
end