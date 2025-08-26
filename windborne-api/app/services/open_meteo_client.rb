class OpenMeteoClient
    BASE = "https://api.open-meteo.com/v1/forecast"
    def self.at(lat, lon, time)
        # nearest hour
        url = BASE + "?latitude=#{lat}&longitude=#{lon}&hourly=windspeed_10m,winddirection_10m&timeformat=unixtime&forecast_days=2"
        res = Faraday.get(url)
        raise "meteo fail" unless res.success?
        j = Oj.load(res.body)
        t = j.dig("hourly", "time")
        ws = j.dig("hourly", "windspeed_10m")
        wd = j.dig("hourly", "winddirection_10m")
        raise "shape" unless t && ws && wd
        epoch = time.to_i
        idx = (0...t.length).min_by { |i| (t[i].to_i - epoch).abs }
        { windspeed: ws[idx].to_f, winddirection: wd[idx].to_f }
    end
end