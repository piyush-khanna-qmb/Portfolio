import React from "react";
import { motion } from "framer-motion";

import { fadeIn } from "../utils/motion";
import { Glyph } from "./icons";

/**
 * Small labelled grid for enumerable capability sets, used on the Omni
 * page to show what the harness can actually detect and do.
 *
 * Icons are inline so the grid costs no extra requests, and they share
 * one stroke style so a row of eleven reads as a set rather than a
 * collection of unrelated glyphs.
 */
const Cell = ({ icon, label }) => (
  <div className='flex items-center gap-2.5 bg-tertiary rounded-lg px-3 py-2.5 border border-transparent transition-all duration-200 hover:-translate-y-0.5 hover:border-[#915EFF]/40 hover:shadow-[0_6px_18px_-6px_rgba(145,94,255,0.5)]'>
    <span className='shrink-0 text-[#915EFF]'>
      <Glyph name={icon} className='w-[17px] h-[17px]' />
    </span>
    <span className='text-white text-[13px] leading-tight'>{label}</span>
  </div>
);

const CapabilityGrid = ({ groups }) => (
  <div className='mt-7 flex flex-col gap-7 max-w-3xl'>
    {groups.map((group, gi) => (
      <motion.div key={group.label} variants={fadeIn("up", "spring", gi * 0.12, 0.6)}>
        <h3 className='font-mono text-[13px] sm:text-[14px] tracking-[0.14em] uppercase text-white mb-3.5'>
          {group.label}
          <span className='ml-2.5 text-[#915EFF]'>{group.items.length}</span>
        </h3>
        <div className='grid grid-cols-2 sm:grid-cols-3 gap-2.5'>
          {group.items.map((item) => (
            <Cell key={item.label} icon={item.icon} label={item.label} />
          ))}
        </div>
      </motion.div>
    ))}
  </div>
);

export default CapabilityGrid;
