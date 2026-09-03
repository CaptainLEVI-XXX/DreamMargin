import { useState } from "react";
import { AppShell, type Route } from "./components/AppShell";
import { Card } from "./components/Card";

const TITLES: Record<Route, string> = {
  markets: "Markets",
  positions: "Your positions",
  earn: "Earn",
};

export default function App() {
  const [route, setRoute] = useState<Route>("markets");

  return (
    <AppShell route={route} onNavigate={setRoute}>
      <Card title={TITLES[route]}>
        <p>This screen arrives in the next plan.</p>
      </Card>
    </AppShell>
  );
}
