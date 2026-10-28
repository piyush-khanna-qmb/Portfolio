import React from "react";
import { motion } from "framer-motion";

import { styles } from "../styles";
import { publications } from "../constants";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";

/**
 * Lab-notebook treatment: research as it is recorded rather than as it is
 * published. A continuous left rule runs the length of the section, each
 * entry pinned to it by a node, dated on the left and status-flagged on
 * the right. Adding future entries extends the rule rather than breaking
 * the layout.
 */
const NotebookEntry = ({ index, item }) => (
  <motion.article
    variants={fadeIn("up", "spring", index * 0.16, 0.6)}
    className='relative pb-8 last:pb-1'
  >
    {/* node on the margin rule */}
    <span
      aria-hidden='true'
      className='absolute -left-[32px] top-[6px] w-[9px] h-[9px] rounded-full bg-[#915EFF]'
    />

    {/* Record line: date and reference number on the left, completion
        status on the right, all above the rule. */}
    <header className='flex flex-wrap justify-between gap-x-4 gap-y-1 pb-[7px] mb-[12px] border-b border-white/10'>
      <span className='font-mono text-[11px] tracking-[0.1em] uppercase text-secondary'>
        {item.entryDate}
        {item.entryRef && (
          <>
            <span aria-hidden='true' className='mx-2 text-secondary/40'>
              &#183;
            </span>
            <span className='text-white'>{item.entryRef}</span>
          </>
        )}
      </span>
      <span className='font-mono text-[11px] tracking-[0.1em] uppercase text-[#5de0a0]'>
        {item.entryStatus}
      </span>
    </header>

    <h3 className='text-white font-bold text-[18px] leading-[1.35] max-w-[62ch]'>
      {item.title}
    </h3>

    <p className='mt-[11px] text-secondary text-[13.5px] leading-[1.75] max-w-[82ch]'>
      {item.body}
    </p>

    {/* Sign-off sits beneath the body, as in the approved design. */}
    {item.subtitle && (
      <p className='mt-[13px] flex items-start gap-2 font-mono text-[11.5px] leading-[1.6] text-secondary'>
        <span aria-hidden='true' className='text-[#5de0a0] shrink-0'>
          &#10003;
        </span>
        {item.subtitle}
      </p>
    )}

    {item.keywords && (
      <div className='mt-[14px] flex flex-wrap gap-2'>
        {item.keywords.map((keyword) => (
          <span
            key={keyword}
            className='font-mono text-[10.5px] text-secondary/80 bg-black-100 px-2.5 py-1 rounded'
          >
            {keyword}
          </span>
        ))}
      </div>
    )}
  </motion.article>
);

const Research = () => {
  return (
    <>
      <motion.div variants={textVariant()}>
        <p className={styles.sectionSubText}>Written down and filed</p>
        <h2 className={styles.sectionHeadText}>Research &amp; Patents.</h2>
      </motion.div>

      <motion.p
        variants={fadeIn("", "", 0.1, 1)}
        className='mt-3 text-secondary text-[15px] max-w-3xl leading-[25px]'
      >
        Work that ended up as a formal filing or a paper rather than only a
        machine on a table.
      </motion.p>

      {/* /45 is not a step on Tailwind 3.2's opacity scale, so that class
          silently fails to generate and the border falls back to the
          default gray. Stick to real steps here. */}
      <div className='mt-9 pl-[26px] border-l-2 border-[#915EFF]/50'>
        {publications.map((item, index) => (
          <NotebookEntry key={item.title} index={index} item={item} />
        ))}
      </div>
    </>
  );
};

export default SectionWrapper(Research, "research");
