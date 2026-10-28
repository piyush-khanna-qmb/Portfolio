import React from "react";
import { Link } from "react-router-dom";
import { motion } from "framer-motion";

import { styles } from "../styles";
import { thoughts } from "../constants";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";
import ArrowUpRight from "./ArrowUpRight";

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
      <div className='flex flex-col sm:flex-row sm:items-baseline sm:justify-between gap-1 sm:gap-8'>
        <h3 className='flex items-center gap-2 text-white font-bold text-[18px] sm:text-[20px] leading-[1.4] group-hover:text-[#915EFF] transition-colors duration-300'>
          {post.title}
          {/* Arrow is inline so it costs no vertical space when hidden.
              The old block-level "Read" affordance reserved its height
              even at opacity-0, which added ~32px to every row. */}
          <ArrowUpRight className='w-[18px] h-[18px] shrink-0 text-[#915EFF] opacity-0 -translate-x-1 translate-y-1 group-hover:opacity-100 group-hover:translate-x-0 group-hover:translate-y-0 transition-all duration-300' />
        </h3>
        <span className='shrink-0 text-secondary/70 text-[13px] tabular-nums'>
          {post.date}
        </span>
      </div>

      <p className='mt-1.5 text-secondary text-[15px] leading-[24px] max-w-4xl'>
        {post.dek}
      </p>
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
        className='mt-3 text-secondary text-[15px] max-w-3xl leading-[25px]'
      >
        Longer arguments about why these things exist the way they do: the
        naming, the architecture, and the occasional theological problem that a
        robot creates for you.
      </motion.p>

      <div className='mt-8 border-b border-white/10'>
        {thoughts.map((post, index) => (
          <ThoughtRow key={post.slug} index={index} post={post} />
        ))}
      </div>
    </>
  );
};

export default SectionWrapper(Thoughts, "thoughts");
