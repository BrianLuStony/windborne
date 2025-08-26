import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import App from "./App.tsx";
import "leaflet/dist/leaflet.css";
import L from "leaflet";

// Force Vite to emit proper asset URLs
import marker2x from "leaflet/dist/images/marker-icon-2x.png?url";
import marker from "leaflet/dist/images/marker-icon.png?url";
import shadow from "leaflet/dist/images/marker-shadow.png?url";

L.Icon.Default.mergeOptions({
  iconRetinaUrl: marker2x,
  iconUrl: marker,
  shadowUrl: shadow,
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
