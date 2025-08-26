# app/controllers/api/constellation_controller.rb
class Api::ConstellationController < ActionController::API
  def index
    debug     = ActiveModel::Type::Boolean.new.cast(params[:debug])
    no_meteo  = debug || ActiveModel::Type::Boolean.new.cast(params[:no_meteo])
    max_rows  = (params[:max_rows_per_hour] || (debug ? 200 : nil)).to_i
    max_rows  = nil if max_rows <= 0
    meteo_cap = (params[:meteo_cap] || 60).to_i # cap per-request meteo lookups
    meteo_cap = 60 if meteo_cap <= 0

    t0 = now
    points, fetch_meta = WindborneFetcher.call_with_meta(max_rows_per_hour: max_rows)   # <-- new signature below
    t1 = now
    tracks = FastTrackBuilder.call(points)                                              # <-- faster builder below
    t2 = now

    enriched = if no_meteo
      tracks.map { |tr|
        { id: tr[:id],
          last: tr[:points].last,
          drift: VectorMath.drift(tr),
          meteo: nil, comp: nil,
          trail: tr[:points].map { |p| { lat: p[:lat], lon: p[:lon], t: p[:t] } } }
      }
    else
      # Sample a subset for meteo to keep latency down
      sample = tracks.first(meteo_cap)
      sample.map { |tr|
        last  = tr[:points].last
        drift = VectorMath.drift(tr)
        meteo = begin OpenMeteoClient.at(last[:lat], last[:lon], Time.at(last[:t] / 1000)) rescue nil end
        comp  = meteo ? VectorMath.components(drift[:headingDeg], meteo[:winddirection], meteo[:windspeed]) : nil
        { id: tr[:id], last: last, drift: drift, meteo: meteo, comp: comp,
          trail: tr[:points].map { |p| { lat: p[:lat], lon: p[:lon], t: p[:t] } } }
      }
    end
    t3 = now

    payload = {
      updatedAt: Time.now.utc.iso8601,
      count: enriched.size,
      balloons: enriched,
      insights: {
        fastest: enriched.sort_by { |e| -(e.dig(:drift,:speedKmh) || 0.0) }.first(5),
        bestTail: enriched.select { |e| e[:comp] }.sort_by { |e| -(e.dig(:comp,:tailwind) || 0.0) }.first(5)
      }
    }

    if debug
      payload[:debug] = fetch_meta.merge({
        tracks_total: tracks.size,
        t_fetch_ms: ((t1 - t0) * 1000).to_i,
        t_tracks_ms: ((t2 - t1) * 1000).to_i,
        t_enrich_ms: ((t3 - t2) * 1000).to_i,
        params: { no_meteo: no_meteo, max_rows_per_hour: max_rows, meteo_cap: meteo_cap }
      })
    end

    render json: payload
  end

  private
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
