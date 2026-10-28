import { useEffect } from "react";
import {
  BrowserRouter,
  Routes,
  Route,
  Navigate,
  useLocation,
} from "react-router-dom";

import Home from "./pages/Home";
import PressPage from "./pages/PressPage";
import ThoughtPost from "./pages/ThoughtPost";
import ProjectPage from "./pages/ProjectPage";

/**
 * Derived from Vite's base rather than hardcoded, so the router keeps
 * working if `base` changes at deploy time (see Standing Rule 11 — the
 * real deploy config is still deferred).
 */
const basename =
  ("/" + (import.meta.env.BASE_URL || "/"))
    .replace(/\/+/g, "/")
    .replace(/\/$/, "") || "/";

/**
 * Route changes should land at the top of the new page. Anchor links
 * (#about etc.) are left alone so in-page navigation still works.
 */
const ScrollToTop = () => {
  const { pathname, hash } = useLocation();

  useEffect(() => {
    if (hash) return;
    window.scrollTo(0, 0);
  }, [pathname, hash]);

  return null;
};

const App = () => {
  return (
    <BrowserRouter basename={basename}>
      <ScrollToTop />
      <Routes>
        <Route path='/' element={<Home />} />
        <Route path='/press' element={<PressPage />} />
        <Route path='/thoughts/:slug' element={<ThoughtPost />} />
        <Route path='/project/:slug' element={<ProjectPage />} />
        <Route path='*' element={<Navigate to='/' replace />} />
      </Routes>
    </BrowserRouter>
  );
};

export default App;
