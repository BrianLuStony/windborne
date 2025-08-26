import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css"; // your styles
import "./leaflet.setup"; // ensure CSS is loaded once
import App from "./App";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
