import React, { useEffect, useRef, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";

/**
 * Floating jump-to-top control for the standalone pages.
 *
 * It stays hidden until the reader actually reaches the end of the
 * content, rather than appearing after an arbitrary scroll distance. A
 * one-pixel sentinel is rendered at the end of the page body and an
 * IntersectionObserver watches it, so the trigger is "the end is on
 * screen" regardless of how long the page happens to be.
 */
const BackToTop = () => {
  const sentinel = useRef(null);
  const [atEnd, setAtEnd] = useState(false);

  useEffect(() => {
    const el = sentinel.current;
    if (!el || typeof IntersectionObserver === "undefined") return undefined;

    const observer = new IntersectionObserver(
      ([entry]) => setAtEnd(entry.isIntersecting),
      { rootMargin: "0px 0px -8% 0px" }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const toTop = () => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    window.scrollTo({ top: 0, behavior: reduced ? "auto" : "smooth" });
  };

  return (
    <>
      <div ref={sentinel} aria-hidden='true' className='h-px w-full' />

      <AnimatePresence>
        {atEnd && (
          <motion.button
            type='button'
            onClick={toTop}
            aria-label='Back to top'
            title='Back to top'
            initial={{ opacity: 0, y: 14 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: 14 }}
            transition={{ duration: 0.22 }}
            className='fixed bottom-6 right-6 sm:bottom-8 sm:right-8 z-50 w-12 h-12 rounded-full bg-[#915EFF]/80 hover:bg-[#915EFF] text-white flex items-center justify-center shadow-[0_0_25px_rgba(145,94,255,0.45)] hover:shadow-[0_0_35px_rgba(145,94,255,0.7)] transition-colors duration-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-white/70'
          >
            <svg
              viewBox='0 0 24 24'
              fill='none'
              stroke='currentColor'
              strokeWidth={2}
              strokeLinecap='round'
              strokeLinejoin='round'
              className='w-5 h-5'
              aria-hidden='true'
            >
              <line x1='12' y1='19' x2='12' y2='5' />
              <polyline points='5 12 12 5 19 12' />
            </svg>
          </motion.button>
        )}
      </AnimatePresence>
    </>
  );
};

export default BackToTop;
