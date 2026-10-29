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
 * working if `base` changes at deploy time (see Standing Rule 11, the
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

/**
 * Flips a DOM marker once the matched route has mounted. React fires
 * child effects before parent/sibling effects in render order, so as
 * long as this sits AFTER <Routes> here, the route's own <Helmet> tags
 * (set inside Home/PressPage/ThoughtPost/ProjectPage) have already
 * committed by the time this runs. scripts/prerender.mjs polls for this
 * attribute before capturing the page, instead of guessing with a fixed
 * timeout.
 */
const PrerenderReadyMarker = () => {
  useEffect(() => {
    document.body.setAttribute("data-prerender-ready", "true");
  }, []);

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
      <PrerenderReadyMarker />
    </BrowserRouter>
  );
};

export default App;
