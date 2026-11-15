import { useEffect, useRef, useState } from "react";

/**
 * Mounts a heavy child (a WebGL canvas) once it first nears the viewport,
 * then leaves it mounted for good. This staggers expensive initial mounts
 * across scroll time instead of creating every GPU context in the same
 * frame, without ever tearing one down and re-rendering it on a revisit.
 */
const useInView = (rootMargin = "150px") => {
  const ref = useRef(null);
  const [inView, setInView] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el || typeof IntersectionObserver === "undefined") {
      setInView(true);
      return undefined;
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setInView(true);
          observer.disconnect();
        }
      },
      { rootMargin }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [rootMargin]);

  return [ref, inView];
};

export default useInView;
