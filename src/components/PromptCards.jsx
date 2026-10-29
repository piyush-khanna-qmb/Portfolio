import React from "react";
import { motion } from "framer-motion";

import { fadeIn } from "../utils/motion";
import TriggerViz from "./TriggerViz";
import AdvancedFeature from "./AdvancedFeature";

const SMALL = {
  radar: <><path d='M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z' /><circle cx='12' cy='10' r='3' /></>,
  pin: <><path d='M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z' /><circle cx='12' cy='10' r='3' /></>,
  apps: <><rect x='3' y='3' width='7' height='7' rx='1.5' /><rect x='14' y='3' width='7' height='7' rx='1.5' /><rect x='3' y='14' width='7' height='7' rx='1.5' /><rect x='14' y='14' width='7' height='7' rx='1.5' /></>,
  clock: <><circle cx='12' cy='12' r='9' /><polyline points='12 7 12 12 15.5 14' /></>,
  level: <><polygon points='11 5 6 9 2 9 2 15 6 15 11 19 11 5' /><path d='M15.5 8.5a5 5 0 0 1 0 7' /></>,
};

const SmallIcon = ({ kind }) => (
  <span className='w-[34px] h-[34px] shrink-0 rounded-lg bg-[#915EFF]/[0.13] border border-[#915EFF]/30 grid place-items-center text-[#915EFF]'>
    <svg
      viewBox='0 0 24 24'
      fill='none'
      stroke='currentColor'
      strokeWidth={1.8}
      strokeLinecap='round'
      strokeLinejoin='round'
      className='w-[15px] h-[15px]'
      aria-hidden='true'
    >
      {SMALL[kind] || SMALL.radar}
    </svg>
  </span>
);

/**
 * Prompt showcase for the Omni page, in two layouts.
 *
 * "split"  : compact card, trigger graphic on the left, sentence beside
 *            it rather than beneath. Used for the short scenarios so a
 *            row of three actually fills its width.
 * "scope"  : one large graphic beside a long routine. The advanced
 *            prompts are several lines each and would be unreadable
 *            squeezed into a card.
 *
 * The sentence is the product, so in both layouts it is the hero:
 * monospace, behind an accent rule.
 */
const Prompt = ({ text, size = "text-[13px]" }) => (
  <blockquote className='border-l-2 border-[#915EFF]/50 pl-3.5'>
    <p className={`font-mono text-white leading-[1.65] ${size}`}>
      &ldquo;{text}&rdquo;
    </p>
  </blockquote>
);

const Outcome = ({ text }) => (
  <p className='flex items-start gap-2 text-secondary text-[13px] leading-[20px]'>
    <span aria-hidden='true' className='text-[#915EFF] shrink-0'>
      &#8627;
    </span>
    {text}
  </p>
);

const SplitCard = ({ index, item }) => (
  <motion.div
    variants={fadeIn("up", "spring", (index % 3) * 0.1, 0.6)}
    className='bg-tertiary rounded-xl p-[18px] flex gap-4 items-start border border-transparent hover:border-[#915EFF]/30 transition-colors duration-300'
  >
    <TriggerViz kind={item.viz} />
    <div className='flex flex-col gap-2.5 min-w-0'>
      {item.kind && (
        <p className='font-mono text-[10px] tracking-[0.16em] uppercase text-[#915EFF]'>
          {item.kind}
        </p>
      )}
      <Prompt text={item.prompt} size='text-[12.5px]' />
      <Outcome text={item.note} />
    </div>
  </motion.div>
);

/* One large radar anchors the group and the routines run beside it as a
   list. Each long prompt gets the full remaining width, which is what
   they need: squeezed into cards they were unreadable. */
const ScopeGroup = ({ items }) => (
  <div className='grid lg:grid-cols-[300px_1fr] gap-8 lg:gap-12 items-start'>
    <TriggerViz
      kind='radar'
      className='w-[210px] h-[210px] lg:w-[300px] lg:h-[300px] mx-auto lg:mx-0 lg:sticky lg:top-28'
    />

    <div>
      {items.map((item, i) => (
        <motion.div
          key={item.prompt}
          variants={fadeIn("up", "spring", (i % 3) * 0.1, 0.6)}
          className='grid grid-cols-[34px_1fr] gap-4 py-5 border-b border-white/10 last:border-b-0 items-start'
        >
          <SmallIcon kind={item.viz} />
          <div className='flex flex-col gap-2.5 min-w-0'>
            {item.label && (
              <p className='font-mono text-[10.5px] tracking-[0.16em] uppercase text-[#915EFF]'>
                {item.label}
              </p>
            )}
            <Prompt text={item.prompt} />
            <Outcome text={item.note} />
          </div>
        </motion.div>
      ))}
    </div>
  </div>
);

const PromptCards = ({ groups }) => (
  <div className='mt-7 flex flex-col gap-10'>
    {groups.map((group) => (
      <div key={group.label}>
        <h3 className='font-mono text-[13px] sm:text-[14px] tracking-[0.14em] uppercase text-white mb-4'>
          {group.label}
          <span className='ml-2.5 text-[#915EFF]'>{group.items.length}</span>
        </h3>

        {group.layout === "feature" ? (
          <div className='flex flex-col divide-y divide-white/10'>
            {group.items.map((item) => (
              <AdvancedFeature key={item.title} feature={item} />
            ))}
          </div>
        ) : group.layout === "scope" ? (
          <ScopeGroup items={group.items} />
        ) : (
          <div className='grid gap-3.5 md:grid-cols-2 xl:grid-cols-3'>
            {group.items.map((item, i) => (
              <SplitCard key={item.prompt} index={i} item={item} />
            ))}
          </div>
        )}
      </div>
    ))}
  </div>
);

export default PromptCards;
