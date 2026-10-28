import React, { useEffect, useCallback } from "react";
import { createPortal } from "react-dom";
import { motion, AnimatePresence } from "framer-motion";

/**
 * Shared zoom overlay used by both the certificate wall and the photo
 * gallery, so the two behave identically.
 *
 * Rendered through a portal to document.body on purpose: SectionWrapper
 * wraps every section in `relative z-0`, which creates a stacking context.
 * A fixed-position child inside that context would be trapped by it and
 * could be painted over by later sections. The portal escapes it.
 */
const Lightbox = ({ item, onClose }) => {
  const handleKey = useCallback(
    (e) => {
      if (e.key === "Escape") onClose();
    },
    [onClose]
  );

  useEffect(() => {
    if (!item) return undefined;

    document.addEventListener("keydown", handleKey);
    // Freeze background scroll while the overlay is up.
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    return () => {
      document.removeEventListener("keydown", handleKey);
      document.body.style.overflow = previousOverflow;
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
          aria-label={item.title}
          className='fixed inset-0 z-[100] flex items-center justify-center p-4 sm:p-8 bg-black/85 backdrop-blur-sm cursor-zoom-out'
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
            initial={{ scale: 0.94, y: 12 }}
            animate={{ scale: 1, y: 0 }}
            exit={{ scale: 0.94, y: 12 }}
            transition={{ type: "spring", damping: 26, stiffness: 260 }}
            onClick={(e) => e.stopPropagation()}
            className='cursor-default max-w-5xl w-full max-h-full flex flex-col gap-4 overflow-y-auto'
          >
            <img
              src={item.image}
              alt={item.title}
              className='w-full max-h-[62vh] object-contain rounded-xl bg-black/30'
            />

            <div className='bg-tertiary rounded-xl p-5 sm:p-6'>
              <h3 className='text-white font-bold text-[19px] sm:text-[22px]'>
                {item.title}
              </h3>

              {(item.issuer || item.date) && (
                <p className='mt-1 text-[13px] text-[#915EFF] font-medium'>
                  {[item.issuer, item.date].filter(Boolean).join(" · ")}
                </p>
              )}

              {(item.blurb || item.caption) && (
                <p className='mt-3 text-secondary text-[15px] leading-[26px]'>
                  {item.blurb || item.caption}
                </p>
              )}
            </div>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>,
    document.body
  );
};

export default Lightbox;
