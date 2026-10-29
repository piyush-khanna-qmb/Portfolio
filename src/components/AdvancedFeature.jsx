import React from "react";
import { motion } from "framer-motion";

import { fadeIn } from "../utils/motion";
import TriggerViz from "./TriggerViz";
import { Glyph } from "./icons";

/**
 * One advanced Omni routine, shown end to end.
 *
 * Title and framing first, then the sentence a user would actually type,
 * then the decomposition: each clause of that sentence mapped to what the
 * harness schedules and which Android primitive does the work. The point
 * is to show that a long plain-English instruction resolves to a small
 * set of ordinary OS calls.
 */
const Step = ({ step, index }) => (
  <motion.li
    variants={fadeIn("up", "spring", (index % 3) * 0.08, 0.55)}
    className='grid grid-cols-[30px_1fr] gap-4 py-5 border-b border-white/[0.07] last:border-b-0 items-start'
  >
    <span className='w-[30px] h-[30px] mt-px shrink-0 rounded-lg bg-[#915EFF]/[0.13] border border-[#915EFF]/30 grid place-items-center text-[#915EFF]'>
      <Glyph name={step.icon} className='w-[14px] h-[14px]' />
    </span>

    <div className='min-w-0 flex flex-col gap-2'>
      <p className='font-mono text-[12px] leading-[1.6] text-white/80'>
        &ldquo;{step.fragment}&rdquo;
      </p>
      <p className='flex items-start gap-2 text-white text-[13.5px] leading-[21px]'>
        <span aria-hidden='true' className='text-[#915EFF] shrink-0'>
          &#8627;
        </span>
        {step.result}
      </p>
      {/* The API name is metadata, not a third line of prose. Boxing it
          stops the green monospace competing with the quoted fragment
          above it, which is what made a column of these read as noise. */}
      <span className='self-start font-mono text-[10.5px] leading-[1.5] text-[#5de0a0]/70 bg-[#5de0a0]/[0.06] border border-[#5de0a0]/20 rounded px-2 py-1 break-words'>
        {step.api}
      </span>
    </div>
  </motion.li>
);

const AdvancedFeature = ({ feature }) => (
  <motion.article
    variants={fadeIn("up", "spring", 0.05, 0.6)}
    className='py-10 first:pt-0 last:pb-0'
  >
    <h4 className='text-white font-bold text-[20px] sm:text-[23px] leading-[1.3]'>
      {feature.title}
    </h4>

    <blockquote className='mt-5 border-l-2 border-[#915EFF]/55 pl-4'>
      <p className='text-secondary text-[15px] leading-[26px]'>
        &ldquo;{feature.prompt}&rdquo;
      </p>
    </blockquote>

    {/* graphic beside the decomposition, as its own row below the prompt */}
    <div className='mt-7 grid lg:grid-cols-[220px_1fr] gap-7 lg:gap-10 items-start'>
      <TriggerViz
        kind={feature.viz}
        className='w-[160px] h-[160px] lg:w-[220px] lg:h-[220px] mx-auto lg:mx-0'
      />
      <ol className='min-w-0'>
        {feature.steps.map((step, i) => (
          <Step key={step.fragment} step={step} index={i} />
        ))}
      </ol>
    </div>
  </motion.article>
);

export default AdvancedFeature;
