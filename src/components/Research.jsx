import React from "react";
import { motion } from "framer-motion";

import { styles } from "../styles";
import { publications } from "../constants";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";

const PublicationCard = ({ index, item }) => (
  <motion.article
    variants={fadeIn("up", "spring", index * 0.18, 0.7)}
    className='bg-tertiary rounded-2xl p-7 sm:p-8 flex flex-col gap-4 border border-transparent hover:border-[#915EFF]/30 transition-colors duration-300'
  >
    <div className='flex flex-wrap items-center gap-3'>
      <span className='bg-[#915EFF]/20 text-[#915EFF] text-[11px] font-bold uppercase tracking-[0.12em] px-3 py-1 rounded-full'>
        {item.kind}
      </span>
      {item.date && (
        <span className='text-secondary/70 text-[12px]'>{item.date}</span>
      )}
    </div>

    <h3 className='text-white font-bold text-[20px] sm:text-[22px] leading-[30px]'>
      {item.title}
    </h3>

    <p className='text-[#915EFF] text-[13px] font-medium'>{item.meta}</p>

    <p className='text-secondary text-[15px] leading-[26px]'>{item.body}</p>

    <p className='text-secondary/80 text-[13px] leading-[21px] italic'>
      {item.authors}
    </p>

    {item.keywords && (
      <div className='flex flex-wrap gap-2 pt-1'>
        {item.keywords.map((keyword) => (
          <span
            key={keyword}
            className='text-[12px] text-secondary bg-black-100 px-2.5 py-1 rounded-md'
          >
            {keyword}
          </span>
        ))}
      </div>
    )}

    {item.status && (
      <p className='mt-auto pt-2 text-secondary/60 text-[12px]'>
        {item.status}
      </p>
    )}
  </motion.article>
);

const Research = () => {
  return (
    <>
      <motion.div variants={textVariant()}>
        <p className={styles.sectionSubText}>Written down and filed</p>
        <h2 className={styles.sectionHeadText}>Research & Patents.</h2>
      </motion.div>

      <motion.p
        variants={fadeIn("", "", 0.1, 1)}
        className='mt-3 text-secondary text-[17px] max-w-3xl leading-[30px]'
      >
        Work that ended up as a formal filing or a paper rather than only a
        machine on a table.
      </motion.p>

      <div className='mt-14 grid grid-cols-1 lg:grid-cols-2 gap-6'>
        {publications.map((item, index) => (
          <PublicationCard key={item.title} index={index} item={item} />
        ))}
      </div>
    </>
  );
};

export default SectionWrapper(Research, "research");
