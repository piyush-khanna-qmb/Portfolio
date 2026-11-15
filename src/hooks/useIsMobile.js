import { useEffect, useState } from "react";

const useIsMobile = (query = "(max-width: 500px)") => {
  const [isMobile, setIsMobile] = useState(
    () => typeof window !== "undefined" && window.matchMedia(query).matches
  );

  useEffect(() => {
    const mql = window.matchMedia(query);
    setIsMobile(mql.matches);
    const onChange = (event) => setIsMobile(event.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, [query]);

  return isMobile;
};

export default useIsMobile;
