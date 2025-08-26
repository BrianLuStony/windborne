# app/controllers/api/constellation_controller.rb
class Api::ConstellationController < ActionController::API
  def index
    bool = ActiveModel::Type::Boolean.new

    # --- flags & params ---
    debug     = bool.cast(params[:debug])
    # Default meteo OFF unless ENV ENABLE_METEO=true; param ?no_meteo=… overrides.
    env_enable = bool.cast(ENV.fetch("ENABLE_METEO", "false"))
    no_meteo   = if params.key?(:no_meteo)
                   bool.cast(params[:no_meteo])
                 else
                   !env_enable
                 end

    meteo_cap = (params[:meteo_cap].presence || 40).to_i
    meteo_cap = 0 if meteo_cap.negative?

    max_rows = params[:max_rows_per_hour].presence&.to_i
    max_rows = nil if max_rows && max_rows <= 0

    # Hard cap for number of balloons returned (independent of meteo_cap)
    cap_param = (params[:cap] || params[:limit] || params[:tracks_cap]).presence&.to_i
    cap_param = nil if cap_param && cap_param <= 0

    order = (params[:order].presence || "fastest") # fastest | recent | random

    cache_key = [
      "constellation:v10",
      "no_meteo=#{no_meteo}",
      "meteo_cap=#{meteo_cap}",
      "max_rows=#{max_rows || 'nil'}",
      "cap=#{cap_param || 'nil'}",
      "order=#{order}"
    ].join(":")

    if debug
      payload = build_payload(
        no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows,
        cap_param: cap_param, order: order, debug: true
      )
      response.set_header "Cache-Control", "no-store"
      render json: payload and return
    end

    # Safe cache block (works even if Solid Cache table is missing)
    payload =
      begin
        Rails.cache.fetch(cache_key, expires_in: 90.seconds) do
          build_payload(
            no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows,
            cap_param: cap_param, order: order, debug: false
          )
        end
      rescue => e
        Rails.logger.warn("cache_fetch_failed: #{e.class}: #{e.message}") rescue nil
        build_payload(
          no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows,
          cap_param: cap_param, order: order, debug: false
        )
      end

    response.set_header "Cache-Control", "public, max-age=60"
    render json: payload
  end

  private

  def build_payload(no_meteo:, meteo_cap:, max_rows:, cap_param:, order:, debug:)
    t0 = mono
    points, fetch_meta = WindborneFetcher.call_with_meta(max_rows_per_hour: max_rows)
    t1 = mono

    tracks = FastTrackBuilder.call(points) # [{ id:, points:[{lat,lon,t}, ...] }, ...]
    t2 = mono

    # Map raw tracks to lightweight balloon records
    base_all = tracks.map do |tr|
      pts = tr[:points] || []
      next if pts.empty?
      last  = pts.last
      drift = VectorMath.drift(tr) # { speedKmh:, headingDeg: }
      {
        id:    tr[:id],
        last:  last,
        drift: drift,
        meteo: nil,
        comp:  nil,
        trail: pts.map { |p| { lat: p[:lat], lon: p[:lon], t: p[:t] } }
      }
    end.compact

    # Apply order + hard cap (limit the balloons we return)
    base = sort_for_order(base_all, order)
    base = base.first(cap_param) if cap_param

    # --- Optional wind enrichment on a subset (does not change count) ---
    enriched_map   = {}
    subset         = []
    meteo_attempts = 0
    meteo_success  = 0
    meteo_errors   = []
    meteo_probes   = [] # kept for debug if you use fetch(..., want_debug:true)

    unless no_meteo || meteo_cap <= 0 || base.empty?
      subset = sort_for_order(base, "fastest").first(meteo_cap) # enrich fastest N

      subset.each_with_index do |e, i|
        meteo_attempts += 1
        last  = e[:last]
        drift = e[:drift]
        begin
          # If you have a debug path in your client, you can capture a few probes here.
          m = OpenMeteoClient.at(last[:lat], last[:lon], Time.at(last[:t] / 1000))
          if m
            c = VectorMath.components(drift[:headingDeg], m[:winddirection], m[:windspeed])
            enriched_map[e[:id]] = { meteo: m, comp: c }
            meteo_success += 1
          else
            meteo_errors << "nil meteo at #{last[:lat]},#{last[:lon]}"
          end
        rescue => ex
          meteo_errors << "#{ex.class}: #{ex.message}"
        end
      end

      meteo_errors.uniq!
      meteo_errors = meteo_errors.first(5)
    end

    # Merge enrichment
    balloons = base.map { |e| (extra = enriched_map[e[:id]]) ? e.merge(extra) : e }
    t3 = mono

    fastest   = balloons.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) }.first(5) || []
    best_tail = balloons.select { |e| e[:comp].is_a?(Hash) }
                        .sort_by { |e| -(e.dig(:comp, :tailwind) || 0.0) }
                        .first(5) || []

    payload = {
      updatedAt: Time.now.utc.iso8601,
      count: balloons.size,
      balloons: balloons,
      insights: {
        fastest:  fastest,
        bestTail: best_tail
      },
      info: {
        meteo_enabled: (no_meteo ? false : true),
        order: order,
        cap: cap_param
      }
    }

    if debug
      payload[:debug] = (fetch_meta || {}).merge(
        {
          tracks_total: tracks.size,
          base_total_before_cap: base_all.size,
          base_total_after_cap: balloons.size,
          subset_size: subset.size,
          enriched_count: enriched_map.size,
          meteo: {
            attempts: meteo_attempts,
            success:  meteo_success,
            errors_sample: meteo_errors,
            probes: meteo_probes
          },
          timings_ms: {
            fetch:  ((t1 - t0) * 1000).to_i,
            tracks: ((t2 - t1) * 1000).to_i,
            enrich: ((t3 - t2) * 1000).to_i
          },
          params: {
            no_meteo: no_meteo,
            meteo_cap: meteo_cap,
            max_rows_per_hour: max_rows,
            cap: cap_param,
            order: order
          },
          insights_counts: {
            fastest: fastest.length,
            bestTail: best_tail.length
          }
        }
      )
    end

    payload
  end

  def sort_for_order(list, ord)
    case ord
    when "recent" then list.sort_by { |e| -(e.dig(:last, :t) || 0) }
    when "random" then list.shuffle
    else               list.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) } # fastest (default)
    end
  end
  private :sort_for_order

  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
