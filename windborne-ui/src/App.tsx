import React, { useEffect, useMemo, useState } from "react";
import {
  MapContainer,
  TileLayer,
  Polyline,
  Marker,
  Popup,
} from "react-leaflet";
import type { LatLngExpression } from "leaflet";

type Balloon = any; // keep loose for now

type Payload = {
  updatedAt: string;
  count: number;
  balloons: Balloon[];
  insights: { fastest: any[]; bestTail: any[] };
  debug?: any;
};

function App() {
  const [data, setData] = useState<Payload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const center = useMemo<LatLngExpression>(() => [20, 0], []);

  async function load() {
    try {
      const base = import.meta.env.VITE_API_BASE || "http://localhost:4000";
      // Add ?debug=1 if you enabled the debug meta on the Rails endpoint
      const url = `${base}/api/constellation`;
      const res = await fetch(url, { cache: "no-store" });

      if (!res.ok) {
        setErr(`API ${res.status} ${res.statusText}`);
        setData(null);
        return;
      }

      const j = await res.json();
      // Safe defaults so UI never explodes
      const safe: Payload = {
        updatedAt: j?.updatedAt ?? new Date().toISOString(),
        count: Number.isFinite(j?.count) ? j.count : 0,
        balloons: Array.isArray(j?.balloons) ? j.balloons : [],
        insights: {
          fastest: Array.isArray(j?.insights?.fastest)
            ? j.insights.fastest
            : [],
          bestTail: Array.isArray(j?.insights?.bestTail)
            ? j.insights.bestTail
            : [],
        },
        debug: j?.debug,
      };
      setData(safe);
      setErr(null);

      // Optional: peek at fetcher meta if you added it on the server
      if (safe.debug) console.log("Constellation debug:", safe.debug);
    } catch (e: any) {
      setErr(String(e));
      setData(null);
    }
  }

  useEffect(() => {
    load();
    const id = setInterval(load, 5 * 60 * 1000);
    return () => clearInterval(id);
  }, []);

  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "2fr 1fr",
        minHeight: "100vh",
      }}
    >
      <div>
        <MapContainer center={center} zoom={2} style={{ height: "100vh" }}>
          <TileLayer url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png" />

          {(data?.balloons ?? []).map((b: any) => {
            const trail = (b?.trail ?? []).map((p: any) => [
              p.lat,
              p.lon,
            ]) as LatLngExpression[];
            const last = [b?.last?.lat, b?.last?.lon] as LatLngExpression;

            return (
              <React.Fragment key={b?.id ?? Math.random()}>
                {trail.length > 1 && <Polyline positions={trail} />}
                {Number.isFinite(b?.last?.lat) &&
                  Number.isFinite(b?.last?.lon) && (
                    <Marker position={last}>
                      <Popup>
                        <div style={{ fontSize: 12 }}>
                          <b>{b?.id ?? "balloon"}</b>
                          <br />
                          Updated:{" "}
                          {b?.last?.t
                            ? new Date(b.last.t).toLocaleString()
                            : "–"}
                          <br />
                          Drift:{" "}
                          {b?.drift?.speedKmh != null
                            ? `${b.drift.speedKmh.toFixed(1)} km/h`
                            : "–"}{" "}
                          @{" "}
                          {b?.drift?.headingDeg != null
                            ? `${b.drift.headingDeg.toFixed(0)}°`
                            : "–"}
                          <br />
                          {b?.meteo ? (
                            <>
                              Wind: {b.meteo.windspeed?.toFixed?.(1) ?? "–"}{" "}
                              km/h @{" "}
                              {b.meteo.winddirection?.toFixed?.(0) ?? "–"}°
                              <br />
                              Tail: {b?.comp?.tailwind?.toFixed?.(1) ??
                                "–"}{" "}
                              km/h · Cross:{" "}
                              {b?.comp?.crosswind?.toFixed?.(1) ?? "–"} km/h · Δ{" "}
                              {b?.comp?.deltaDeg?.toFixed?.(0) ?? "–"}°
                            </>
                          ) : (
                            "No meteo"
                          )}
                        </div>
                      </Popup>
                    </Marker>
                  )}
              </React.Fragment>
            );
          })}
        </MapContainer>
      </div>

      <aside style={{ padding: 16 }}>
        <h1>WindBorne · 24h</h1>
        {err && <p style={{ color: "crimson" }}>{err}</p>}

        {data && (
          <>
            <div>
              Last update: {new Date(data.updatedAt).toLocaleString()} ·
              Balloons: {data.count}
            </div>

            {data.count === 0 && !err && (
              <p style={{ opacity: 0.7 }}>
                No tracks in the last 24–48h (yet). Try refresh, or check your
                API at <code>/api/constellation?debug=1</code> if you added
                debug.
              </p>
            )}

            <section>
              <h3>Fastest</h3>
              <ul>
                {(data.insights?.fastest ?? []).map((b: any) => (
                  <li key={b?.id ?? Math.random()}>
                    {b?.id ?? "balloon"}:{" "}
                    {b?.drift?.speedKmh != null
                      ? b.drift.speedKmh.toFixed(1)
                      : "–"}{" "}
                    km/h
                  </li>
                ))}
              </ul>
            </section>

            <section>
              <h3>Best Tailwind</h3>
              <ul>
                {(data.insights?.bestTail ?? []).map((b: any) => (
                  <li key={b?.id ?? Math.random()}>
                    {b?.id ?? "balloon"}: tail{" "}
                    {b?.comp?.tailwind != null
                      ? b.comp.tailwind.toFixed(1)
                      : "–"}{" "}
                    km/h, Δ{" "}
                    {b?.comp?.deltaDeg != null
                      ? b.comp.deltaDeg.toFixed(0)
                      : "–"}
                    °
                  </li>
                ))}
              </ul>
            </section>
          </>
        )}
      </aside>
    </div>
  );
}
export default App;
