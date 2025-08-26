import { useEffect, useMemo, useState, useRef } from "react";
import {
  MapContainer,
  TileLayer,
  Polyline,
  Marker,
  Popup,
  CircleMarker,
} from "react-leaflet";
import { defaultIcon } from "./leaflet.setup";

function App() {
  const [data, setData] = useState<any>();
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(true); // <— NEW
  const firstLoadDone = useRef(false); // avoid flicker on interval refreshes
  const center = useMemo<[number, number]>(() => [20, 0], []);

  const base = import.meta.env.VITE_API_BASE;
  const q = import.meta.env.VITE_API_QUERY || "";
  const url = `${base}/api/constellation${q}`;

  async function load() {
    try {
      if (!firstLoadDone.current) setLoading(true); // only show banner on first load
      const res = await fetch(url, { cache: "no-store" });
      const json = await res.json();
      setData(json);
      setErr(null);
    } catch (e: any) {
      setErr(String(e));
    } finally {
      firstLoadDone.current = true;
      setLoading(false);
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
      <div style={{ position: "relative" }}>
        {/* Loading banner over the map */}
        {loading && (
          <div
            style={{
              position: "absolute",
              zIndex: 1000,
              top: 12,
              left: 12,
              padding: "8px 12px",
              background: "rgba(0,0,0,0.6)",
              color: "white",
              borderRadius: 8,
              fontSize: 14,
            }}
          >
            Loading live constellation… this may take a few seconds.
          </div>
        )}

        <MapContainer center={center} zoom={2} style={{ height: "100vh" }}>
          <TileLayer url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png" />

          {/* Quick visual fallback: draw a few points even if markers had issues before */}
          {(data?.balloons ?? [])
            .slice(0, 3)
            .flatMap((b: any) =>
              (b.trail ?? [])
                .slice(0, 50)
                .map((p: any, i: number) => (
                  <CircleMarker
                    key={`${b.id}-${i}`}
                    center={[p.lat, p.lon] as [number, number]}
                    radius={2}
                  />
                ))
            )}

          {data?.balloons?.map((b: any) => {
            const trail = b.trail.map(
              (p: any) => [p.lat, p.lon] as [number, number]
            );
            const last = [b.last.lat, b.last.lon] as [number, number];
            return (
              <div key={b.id}>
                <Polyline positions={trail} />
                <Marker position={last} icon={defaultIcon}>
                  <Popup>
                    <div style={{ fontSize: 12 }}>
                      <b>{b.id}</b>
                      <br />
                      Updated: {new Date(b.last.t).toLocaleString()}
                      <br />
                      Drift: {b.drift.speedKmh.toFixed(1)} km/h @{" "}
                      {b.drift.headingDeg.toFixed(0)}°<br />
                      {b.meteo ? (
                        <>
                          Wind: {b.meteo.windspeed.toFixed(1)} km/h @{" "}
                          {b.meteo.winddirection.toFixed(0)}°<br />
                          Tail: {b.comp.tailwind.toFixed(1)} km/h · Cross:{" "}
                          {b.comp.crosswind.toFixed(1)} km/h · Δ{" "}
                          {b.comp.deltaDeg.toFixed(0)}°
                        </>
                      ) : (
                        "No meteo"
                      )}
                    </div>
                  </Popup>
                </Marker>
              </div>
            );
          })}
        </MapContainer>
      </div>

      <aside style={{ padding: 16 }}>
        <h1>WindBorne · 24h</h1>
        {err && <p style={{ color: "crimson" }}>{err}</p>}

        {/* Sidebar loading hint */}
        {loading && (
          <div style={{ margin: "8px 0" }}>
            Fetching latest data… this may take a few seconds.
          </div>
        )}

        {data && (
          <>
            <div>
              Last update: {new Date(data.updatedAt).toLocaleString()} ·
              Balloons: {data.count}
            </div>
            <section>
              <h3>Fastest</h3>
              <ul>
                {data.insights.fastest.map((b: any) => (
                  <li key={b.id}>
                    {b.id}: {b.drift.speedKmh.toFixed(1)} km/h
                  </li>
                ))}
              </ul>
            </section>
            <section>
              <h3>Best Tailwind</h3>
              <ul>
                {(data.insights.bestTail ?? []).map((b: any) => (
                  <li key={b.id}>
                    {b.id}: tail {b.comp.tailwind.toFixed(1)} km/h, Δ{" "}
                    {b.comp.deltaDeg.toFixed(0)}°
                  </li>
                ))}
                {(!data.insights.bestTail ||
                  data.insights.bestTail.length === 0) && (
                  <li>Tailwind insights will appear shortly.</li>
                )}
              </ul>
            </section>
          </>
        )}
      </aside>
    </div>
  );
}

export default App;
