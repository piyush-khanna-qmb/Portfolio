import React, { useState } from "react";
import { motion } from "framer-motion";

import { styles } from "../styles";
import { galleryPhotos } from "../constants";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";
import Lightbox from "./Lightbox";

/**
 * Deliberate, hand-set spans rather than a uniform grid, because a photo wall
 * should have rhythm. Index-based so the pattern survives reordering of
 * the data without the layout collapsing.
 */
const spanFor = (index) => {
  const pattern = [
    "sm:col-span-2 sm:row-span-2",
    "sm:col-span-1 sm:row-span-1",
    "sm:col-span-1 sm:row-span-1",
    "sm:col-span-1 sm:row-span-1",
    "sm:col-span-1 sm:row-span-1",
    "sm:col-span-2 sm:row-span-1",
    "sm:col-span-1 sm:row-span-1",
    "sm:col-span-1 sm:row-span-1",
  ];
  return pattern[index % pattern.length];
};

const GalleryTile = ({ index, photo, onOpen }) => (
  <motion.button
    type='button'
    variants={fadeIn("up", "spring", (index % 4) * 0.1, 0.7)}
    onClick={() => onOpen(photo)}
    aria-label={`View photo: ${photo.title}`}
    className={`group relative overflow-hidden rounded-[18px] border border-[#915EFF]/20 shadow-card focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF] aspect-square ${spanFor(
      index
    )}`}
  >
    <img
      src={photo.image}
      alt={photo.title}
      loading='lazy'
      className='w-full h-full object-cover transition-transform duration-500 group-hover:scale-[1.04]'
    />

    {/* Caption plate. The description collapses to zero height rather
        than going transparent, because otherwise it reserves space and pushes
        the title up into the middle of the photo. */}
    <span className='absolute inset-x-0 bottom-0 p-3 sm:p-4 text-left bg-gradient-to-t from-black/85 via-black/45 to-transparent'>
      <span className='block text-white text-[13px] sm:text-[15px] font-semibold leading-tight'>
        {photo.title}
      </span>
      <span className='hidden sm:block overflow-hidden max-h-0 group-hover:max-h-20 transition-[max-height] duration-300 ease-out'>
        <span className='block pt-1.5 text-[12px] leading-[18px] text-white/80 line-clamp-2'>
          {photo.caption}
        </span>
      </span>
    </span>
  </motion.button>
);

const Gallery = () => {
  const [active, setActive] = useState(null);

  return (
    <>
      <motion.div variants={textVariant()}>
        <p className={styles.sectionSubText}>Moments worth keeping</p>
        <h2 className={styles.sectionHeadText}>Gallery.</h2>
      </motion.div>

      <motion.p
        variants={fadeIn("", "", 0.1, 1)}
        className='mt-3 text-secondary text-[17px] max-w-3xl leading-[30px]'
      >
        Rooms, robots and the odd hillside. Click any photo for the story
        behind it.
      </motion.p>

      <div className='mt-14 grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 auto-rows-auto gap-4 sm:gap-5'>
        {galleryPhotos.map((photo, index) => (
          <GalleryTile
            key={photo.title}
            index={index}
            photo={photo}
            onOpen={setActive}
          />
        ))}
      </div>

      <Lightbox item={active} onClose={() => setActive(null)} />
    </>
  );
};

export default SectionWrapper(Gallery, "gallery");
