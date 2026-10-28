import React from "react";
import { Link } from "react-router-dom";
import { motion } from "framer-motion";

import { styles } from "../styles";
import { pressReleases } from "../constants";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";

const ArrowIcon = ({ className = "" }) => (
  <svg
    viewBox='0 0 24 24'
    fill='none'
    stroke='currentColor'
    strokeWidth={2}
    strokeLinecap='round'
    strokeLinejoin='round'
    className={className}
    aria-hidden='true'
  >
    <line x1='7' y1='17' x2='17' y2='7' />
    <polyline points='7 7 17 7 17 17' />
  </svg>
);

const PressCard = ({ index, item }) => (
  <motion.a
    variants={fadeIn("up", "spring", (index % 3) * 0.14, 0.7)}
    href={item.url}
    target='_blank'
    rel='noopener noreferrer'
    className='group bg-tertiary rounded-2xl p-6 flex flex-col gap-3 border border-transparent hover:border-[#915EFF]/40 transition-colors duration-300'
  >
    <div className='flex items-center justify-between gap-3'>
      <span className='text-[#915EFF] text-[12px] font-semibold uppercase tracking-[0.12em]'>
        {item.outlet}
      </span>
      <ArrowIcon className='w-4 h-4 text-secondary group-hover:text-[#915EFF] transition-colors shrink-0' />
    </div>

    <h3 className='text-white font-bold text-[17px] leading-[25px]'>
      {item.title}
    </h3>

    {item.blurb && (
      <p className='text-secondary text-[14px] leading-[22px]'>{item.blurb}</p>
    )}

    {(item.date || item.language) && (
      <p className='mt-auto pt-2 text-secondary/70 text-[12px]'>
        {[item.date, item.language].filter(Boolean).join(" · ")}
      </p>
    )}
  </motion.a>
);

const Press = () => {
  const featured = pressReleases.filter((item) => item.featured);

  return (
    <>
      <motion.div variants={textVariant()}>
        <p className={styles.sectionSubText}>What others wrote</p>
        <h2 className={styles.sectionHeadText}>In the Press.</h2>
      </motion.div>

      <motion.p
        variants={fadeIn("", "", 0.1, 1)}
        className='mt-3 text-secondary text-[17px] max-w-3xl leading-[30px]'
      >
        Anushka was covered across national and international press — from the
        Indian Express and Mint to outlets in Turkey and Hungary. A selection
        below.
      </motion.p>

      <div className='mt-14 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5'>
        {featured.map((item, index) => (
          <PressCard key={item.url} index={index} item={item} />
        ))}
      </div>

      <motion.div
        variants={fadeIn("up", "spring", 0.3, 0.7)}
        className='mt-10 flex justify-center'
      >
        <Link
          to='/press'
          className='group inline-flex items-center gap-2 bg-[#915EFF]/60 hover:bg-[#915EFF]/75 py-3 px-8 rounded-xl text-white font-bold text-[15px] shadow-[0_0_25px_rgba(145,94,255,0.45)] hover:shadow-[0_0_35px_rgba(145,94,255,0.7)] transition-all duration-300'
        >
          See all {pressReleases.length} press mentions
          <ArrowIcon className='w-4 h-4 transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5' />
        </Link>
      </motion.div>
    </>
  );
};

export default SectionWrapper(Press, "press");
