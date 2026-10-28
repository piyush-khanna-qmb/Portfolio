import React from "react";
import { motion } from "framer-motion";

import { styles } from "../styles";
import {
  portfolioPhoto,
  piyushWithAnushka,
  dtuChiefSpeaker,
  profilePhoto,
} from "../assets";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";

const smallPhotos = [
  { src: piyushWithAnushka, caption: "With Anushka", aspect: "aspect-[4/3]" },
  { src: dtuChiefSpeaker, caption: "Chief Speaker, DTU", aspect: "aspect-[4/3]" },
  { src: profilePhoto, caption: "Profile", aspect: "aspect-square" },
];

const PhotoTile = ({ src, caption, aspect = "aspect-square" }) => (
  <div
    className={`relative ${aspect} rounded-[18px] overflow-hidden border border-[#915EFF]/20 shadow-card`}
  >
    <img src={src} alt={caption} className='w-full h-full object-cover' />
    <span className='absolute inset-x-0 bottom-0 px-3 py-2 text-[11.5px] text-white bg-gradient-to-t from-black/70 to-transparent'>
      {caption}
    </span>
  </div>
);

const About = () => {
  return (
    <div className='grid lg:grid-cols-[3fr_2fr] grid-cols-1 gap-x-12 gap-y-8'>
      <div>
        <motion.div variants={textVariant()}>
          <p className={styles.sectionSubText}>Introduction</p>
          <h2 className={styles.sectionHeadText}>Overview.</h2>
        </motion.div>

        <motion.p
          variants={fadeIn("", "", 0.1, 1)}
          className='mt-4 text-secondary text-[17px] max-w-3xl leading-[30px]'
        >
          Highly motivated and driven computer science student with a passion for technology. With a solid foundation in computer science principles and practical experience gained through internships and projects, I am well-equipped to contribute to the complex demands of large multi-site organisations. Let's work together to bring your ideas to life!
        </motion.p>
      </div>

      {/* Desktop: hero photo sits in its own column, the 3 small photos break out
          to span the FULL section width (text column + photo column) below it. */}
      <motion.div
        variants={fadeIn("left", "spring", 0.2, 0.75)}
        className='hidden lg:block aspect-[6/5] rounded-[18px] overflow-hidden border border-[#915EFF]/20 shadow-card'
      >
        <img
          src={portfolioPhoto}
          alt='Piyush Khanna'
          className='w-full h-full object-cover'
        />
      </motion.div>

      <motion.div
        variants={fadeIn("up", "spring", 0.3, 0.75)}
        className='hidden lg:grid lg:col-span-2 grid-cols-[1.15fr_1.15fr_0.7fr] gap-4 items-start'
      >
        {smallPhotos.map((photo) => (
          <PhotoTile key={photo.caption} {...photo} />
        ))}
      </motion.div>

      {/* Mobile: all 4 photos square, stacked 2x2 */}
      <motion.div
        variants={fadeIn("up", "spring", 0.2, 0.75)}
        className='grid grid-cols-2 gap-4 lg:hidden'
      >
        <PhotoTile src={portfolioPhoto} caption='Piyush Khanna' />
        {smallPhotos.map(({ src, caption }) => (
          <PhotoTile key={caption} src={src} caption={caption} />
        ))}
      </motion.div>
    </div>
  );
};

export default SectionWrapper(About, "about");
