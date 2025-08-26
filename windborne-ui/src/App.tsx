import { useEffect, useMemo, useRef, useState } from "react";
import {
  MapContainer,
  TileLayer,
  Polyline,
  Marker,
  Popup,
  CircleMarker,
} from "react-leaflet";
import { defaultIcon } from "./leaflet.setup";

// Types to avoid 'any'
type TrailPoint = { lat: number; lon: number; t: number };
type Drift = { speedKmh: number; headingDeg: number };
type Meteo = { windspeed: number; winddirection: number };
type Comp = { tailwind: number; crosswind: number; deltaDeg: number };
type Balloon = {
  id: string;
  last: TrailPoint;
  drift: Drift;
  meteo?: Meteo | null;
  comp?: Comp | null;
  trail: TrailPoint[];
};
type ApiData = {
  updatedAt: string;
  count: number;
  balloons: Balloon[];
  insights: { fastest: Balloon[]; bestTail?: Balloon[] | null };
  info?: { meteo_enabled?: boolean; meteoEnabled?: boolean };
};

function App() {
  const [data, setData] = useState<ApiData | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const firstLoadDone = useRef(false);

  const center = useMemo<[number, number]>(() => [20, 0], []);

  const base = "";
  const q = import.meta.env.VITE_API_QUERY || "";
  const url = `${base}/api/constellation${q}`;
  console.log(url);
  async function load() {
    try {
      if (!firstLoadDone.current) setLoading(true);
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) {
        const txt = await res.text();
        throw new Error(`HTTP ${res.status} — ${txt.slice(0, 160)}`);
      }
      const json = (await res.json()) as ApiData;
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

          {/* Quick visual fallback dots so you see *something* even if markers hiccup */}
          {(data?.balloons ?? [])
            .slice(0, 3)
            .flatMap((b) =>
              (b.trail ?? [])
                .slice(0, 50)
                .map((p, i) => (
                  <CircleMarker
                    key={`${b.id}-dot-${i}`}
                    center={[p.lat, p.lon]}
                    radius={2}
                  />
                ))
            )}

          {data?.balloons?.map((b) => {
            if (!b?.trail?.length) return null;
            const trail = b.trail.map(
              (p) => [p.lat, p.lon] as [number, number]
            );
            const last: [number, number] = [b.last.lat, b.last.lon];
            return (
              <div key={b.id}>
                <Polyline positions={trail} />
                <Marker position={last} icon={defaultIcon}>
                  <Popup>
                    <div style={{ fontSize: 12, lineHeight: 1.3 }}>
                      <b>{b.id}</b>
                      <br />
                      Updated: {new Date(b.last.t).toLocaleString()}
                      <br />
                      Drift: {b.drift.speedKmh.toFixed(1)} km/h @{" "}
                      {b.drift.headingDeg.toFixed(0)}°
                      <br />
                      {b.meteo && b.comp ? (
                        <>
                          Wind: {b.meteo.windspeed.toFixed(1)} km/h @{" "}
                          {b.meteo.winddirection.toFixed(0)}°
                          <br />
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
        <h1 style={{ marginTop: 0 }}>WindBorne · 24h</h1>

        {err && (
          <p style={{ color: "crimson", whiteSpace: "pre-wrap" }}>{err}</p>
        )}

        {loading && (
          <div style={{ margin: "8px 0" }}>
            Fetching latest data… this may take a few seconds.
          </div>
        )}
      </aside>
    </div>
  );
}

export default App;
