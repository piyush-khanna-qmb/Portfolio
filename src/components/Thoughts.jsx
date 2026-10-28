import React from "react";
import { Link } from "react-router-dom";
import { motion } from "framer-motion";

import { styles } from "../styles";
import { thoughts } from "../constants";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";

/**
 * Line-by-line list rather than cards: these are meant to be read as an
 * index, scanned top to bottom, the way a writing archive reads.
 */
const ThoughtRow = ({ index, post }) => (
  <motion.div variants={fadeIn("up", "spring", index * 0.1, 0.6)}>
    <Link
      to={`/thoughts/${post.slug}`}
      className='group block border-t border-white/10 py-7 focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF] rounded-sm'
    >
      <div className='flex flex-col sm:flex-row sm:items-baseline sm:justify-between gap-2 sm:gap-8'>
        <h3 className='text-white font-bold text-[19px] sm:text-[22px] leading-[30px] group-hover:text-[#915EFF] transition-colors duration-300 max-w-2xl'>
          {post.title}
        </h3>
        <span className='shrink-0 text-secondary/70 text-[13px] tabular-nums'>
          {post.date}
        </span>
      </div>

      <p className='mt-2 text-secondary text-[15px] leading-[26px] max-w-2xl'>
        {post.dek}
      </p>

      <span className='mt-3 inline-flex items-center gap-1.5 text-[13px] font-medium text-[#915EFF] opacity-0 group-hover:opacity-100 transition-opacity duration-300'>
        Read
        <svg
          viewBox='0 0 24 24'
          fill='none'
          stroke='currentColor'
          strokeWidth={2}
          strokeLinecap='round'
          strokeLinejoin='round'
          className='w-3.5 h-3.5'
          aria-hidden='true'
        >
          <line x1='5' y1='12' x2='19' y2='12' />
          <polyline points='12 5 19 12 12 19' />
        </svg>
      </span>
    </Link>
  </motion.div>
);

const Thoughts = () => {
  return (
    <>
      <motion.div variants={textVariant()}>
        <p className={styles.sectionSubText}>The reasoning behind the work</p>
        <h2 className={styles.sectionHeadText}>Why I Built It.</h2>
      </motion.div>

      <motion.p
        variants={fadeIn("", "", 0.1, 1)}
        className='mt-3 text-secondary text-[17px] max-w-3xl leading-[30px]'
      >
        Longer arguments about why these things exist the way they do: the
        naming, the architecture, and the occasional theological problem that a
        robot creates for you.
      </motion.p>

      <div className='mt-12 border-b border-white/10'>
        {thoughts.map((post, index) => (
          <ThoughtRow key={post.slug} index={index} post={post} />
        ))}
      </div>
    </>
  );
};

export default SectionWrapper(Thoughts, "thoughts");
