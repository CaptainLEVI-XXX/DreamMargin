import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles/base.css";
import "./components/primitives.css";
import "./components/safetyBuffer.css";
import "./components/appShell.css";
import "./components/marketCard.css";
import "./components/positionCard.css";
import "./components/leverageTiers.css";
import "./components/protocolAlert.css";
import "./views/views.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
