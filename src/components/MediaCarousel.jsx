import React, { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { motion, AnimatePresence } from "framer-motion";

import ArrowUpRight from "./ArrowUpRight";

/**
 * Media highlights carousel for a project page.
 *
 * Tiles are static: nothing plays until a viewer opens one. Only the
 * player modal gets `autoplay=1`, which is also the only place a
 * third-party iframe is mounted, so the page itself stays light.
 *
 * YouTube tiles use the real video thumbnail. Instagram and Facebook do
 * not expose one without an API token, so those get a branded tile
 * instead of a broken image.
 */

const ytThumb = (id) => `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;

const embedUrl = (item) => {
  if (item.kind === "youtube") {
    return `https://www.youtube-nocookie.com/embed/${item.id}?autoplay=1&rel=0`;
  }
  if (item.kind === "instagram") {
    return `https://www.instagram.com/reel/${item.id}/embed/`;
  }
  return `https://www.facebook.com/plugins/video.php?href=${encodeURIComponent(
    item.url
  )}&autoplay=true`;
};

const watchUrl = (item) => {
  if (item.kind === "youtube") return `https://www.youtube.com/watch?v=${item.id}`;
  if (item.kind === "instagram") return `https://www.instagram.com/reel/${item.id}/`;
  return item.url;
};

const PlayBadge = () => (
  <span className='absolute inset-0 flex items-center justify-center'>
    <span className='w-11 h-11 rounded-full bg-black/55 backdrop-blur-sm flex items-center justify-center transition-transform duration-300 group-hover:scale-110'>
      <svg viewBox='0 0 24 24' className='w-5 h-5 ml-0.5' fill='#fff' aria-hidden='true'>
        <path d='M8 5v14l11-7z' />
      </svg>
    </span>
  </span>
);

const Tile = ({ item, onOpen }) => (
  <button
    type='button'
    onClick={() => onOpen(item)}
    aria-label={`Play ${item.label}`}
    className='group relative shrink-0 snap-start w-[150px] sm:w-[168px] aspect-[9/16] rounded-xl overflow-hidden border border-white/10 bg-black-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF]'
  >
    {item.kind === "youtube" ? (
      <img
        src={ytThumb(item.id)}
        alt=''
        loading='lazy'
        className='w-full h-full object-cover opacity-85 transition-opacity duration-300 group-hover:opacity-100'
      />
    ) : (
      <span
        className={`absolute inset-0 ${
          item.kind === "instagram"
            ? "bg-gradient-to-br from-[#833ab4] via-[#c13584] to-[#f77737]"
            : "bg-gradient-to-br from-[#1877f2] to-[#0b5fce]"
        } opacity-70 transition-opacity duration-300 group-hover:opacity-90`}
      />
    )}

    <PlayBadge />

    <span className='absolute inset-x-0 bottom-0 px-2.5 py-2 text-left text-[10.5px] font-mono tracking-[0.06em] text-white/90 bg-gradient-to-t from-black/85 to-transparent'>
      {item.label}
    </span>
  </button>
);

const Player = ({ item, onClose }) => {
  const handleKey = useCallback(
    (e) => {
      if (e.key === "Escape") onClose();
    },
    [onClose]
  );

  useEffect(() => {
    if (!item) return undefined;
    document.addEventListener("keydown", handleKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", handleKey);
      document.body.style.overflow = prev;
    };
  }, [item, handleKey]);

  return createPortal(
    <AnimatePresence>
      {item && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.2 }}
          onClick={onClose}
          role='dialog'
          aria-modal='true'
          aria-label={item.label}
          className='fixed inset-0 z-[100] flex items-center justify-center p-4 sm:p-8 bg-black/88 backdrop-blur-sm'
        >
          <button
            type='button'
            onClick={onClose}
            aria-label='Close'
            className='absolute top-4 right-4 sm:top-6 sm:right-6 w-10 h-10 rounded-full black-gradient text-white text-xl leading-none flex items-center justify-center hover:text-[#915EFF] transition-colors z-10'
          >
            &times;
          </button>

          <motion.div
            initial={{ scale: 0.95, y: 10 }}
            animate={{ scale: 1, y: 0 }}
            exit={{ scale: 0.95, y: 10 }}
            transition={{ type: "spring", damping: 26, stiffness: 260 }}
            onClick={(e) => e.stopPropagation()}
            className='w-full max-w-[420px] flex flex-col gap-3'
          >
            <div className='relative w-full aspect-[9/16] max-h-[76vh] rounded-xl overflow-hidden bg-black'>
              <iframe
                key={item.id || item.url}
                src={embedUrl(item)}
                title={item.label}
                allow='accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture'
                allowFullScreen
                className='absolute inset-0 w-full h-full border-0'
              />
            </div>

            <a
              href={watchUrl(item)}
              target='_blank'
              rel='noopener noreferrer'
              className='self-center inline-flex items-center gap-1.5 font-mono text-[12px] text-secondary hover:text-[#915EFF] transition-colors'
            >
              Open on {item.label.split(" ")[0]}
              <ArrowUpRight className='w-3.5 h-3.5 shrink-0 text-[#915EFF]' />
            </a>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>,
    document.body
  );
};

const Arrow = ({ dir, onClick }) => (
  <button
    type='button'
    onClick={onClick}
    aria-label={dir === "next" ? "Next clips" : "Previous clips"}
    className='w-9 h-9 rounded-full black-gradient text-white flex items-center justify-center hover:text-[#915EFF] transition-colors'
  >
    <svg
      viewBox='0 0 24 24'
      fill='none'
      stroke='currentColor'
      strokeWidth={2}
      strokeLinecap='round'
      strokeLinejoin='round'
      className={`w-4 h-4 ${dir === "prev" ? "rotate-180" : ""}`}
      aria-hidden='true'
    >
      <line x1='5' y1='12' x2='19' y2='12' />
      <polyline points='12 5 19 12 12 19' />
    </svg>
  </button>
);

const MediaCarousel = ({ videos }) => {
  const trackRef = useRef(null);
  const [active, setActive] = useState(null);
  const [paused, setPaused] = useState(false);

  const scrollByCards = useCallback((direction) => {
    const track = trackRef.current;
    if (!track) return;
    const card = track.firstElementChild;
    const step = card ? card.offsetWidth + 12 : 180;
    track.scrollBy({ left: direction * step * 2, behavior: "smooth" });
  }, []);

  /* The "rolling" part. Pauses on hover, on focus within, when the tab is
     hidden, and entirely for anyone who prefers reduced motion. Wraps back
     to the start once it reaches the end. */
  useEffect(() => {
    const track = trackRef.current;
    if (!track) return undefined;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      return undefined;
    }

    const tick = () => {
      if (paused || document.hidden) return;
      const atEnd =
        track.scrollLeft + track.clientWidth >= track.scrollWidth - 8;
      if (atEnd) {
        track.scrollTo({ left: 0, behavior: "smooth" });
      } else {
        const card = track.firstElementChild;
        const step = card ? card.offsetWidth + 12 : 180;
        track.scrollBy({ left: step, behavior: "smooth" });
      }
    };

    const id = window.setInterval(tick, 3800);
    return () => window.clearInterval(id);
  }, [paused]);

  if (!videos || videos.length === 0) return null;

  return (
    <>
      <div className='flex items-center justify-between gap-4 mb-4'>
        <p className='font-mono text-[11px] tracking-[0.12em] uppercase text-secondary/70'>
          {videos.length} clips
        </p>
        <div className='flex gap-2'>
          <Arrow dir='prev' onClick={() => scrollByCards(-1)} />
          <Arrow dir='next' onClick={() => scrollByCards(1)} />
        </div>
      </div>

      <div
        ref={trackRef}
        onMouseEnter={() => setPaused(true)}
        onMouseLeave={() => setPaused(false)}
        onFocusCapture={() => setPaused(true)}
        onBlurCapture={() => setPaused(false)}
        className='flex gap-3 overflow-x-auto snap-x snap-mandatory pb-2 -mx-1 px-1 scroll-smooth'
      >
        {videos.map((item) => (
          <Tile key={item.id || item.url} item={item} onOpen={setActive} />
        ))}
      </div>

      <Player item={active} onClose={() => setActive(null)} />
    </>
  );
};

export default MediaCarousel;
