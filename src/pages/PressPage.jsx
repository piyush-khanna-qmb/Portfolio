import React from "react";

import { pressReleases, pressSocial } from "../constants";
import ArrowUpRight from "../components/ArrowUpRight";
import PageShell from "./PageShell";

const PressRow = ({ item }) => (
  <a
    href={item.url}
    target='_blank'
    rel='noopener noreferrer'
    className='group block border-t border-white/10 py-6 focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF] rounded-sm'
  >
    <div className='flex flex-col sm:flex-row sm:items-baseline sm:justify-between gap-1.5 sm:gap-8'>
      <div className='max-w-3xl'>
        <span className='text-[#915EFF] text-[11px] font-semibold uppercase tracking-[0.12em]'>
          {item.outlet}
        </span>
        <h3 className='mt-1.5 text-white font-bold text-[17px] sm:text-[19px] leading-[27px] group-hover:text-[#915EFF] transition-colors duration-300'>
          {item.title}
        </h3>
        {item.blurb && (
          <p className='mt-2 text-secondary text-[14px] leading-[23px]'>
            {item.blurb}
          </p>
        )}
      </div>

      <div className='shrink-0 flex items-center gap-3 text-secondary/70 text-[12px]'>
        <span className='tabular-nums'>
          {[item.date, item.language].filter(Boolean).join(" · ")}
        </span>
        <ArrowUpRight className='w-4 h-4 group-hover:text-[#915EFF] transition-colors' />
      </div>
    </div>
  </a>
);

const PressPage = () => (
  <PageShell
    eyebrow='What others wrote'
    title='In the Press.'
    intro={`Where the work has been written about, across ${pressReleases.length} publications in four languages and six countries. The pieces at the top are the ones that got at the thinking rather than only the spectacle.`}
  >
    <section>
      <h2 className='text-white font-bold text-[22px] mb-2'>Publications</h2>
      <div className='border-b border-white/10'>
        {pressReleases.map((item) => (
          <PressRow key={item.url} item={item} />
        ))}
      </div>
    </section>

    <section className='mt-16'>
      <h2 className='text-white font-bold text-[22px]'>
        Broadcast &amp; social
      </h2>
      <p className='mt-2 text-secondary text-[15px] leading-[26px] max-w-3xl'>
        Short-form and video pickups.
      </p>

      <div className='mt-7 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4'>
        {pressSocial.map((item) => (
          <a
            key={item.url}
            href={item.url}
            target='_blank'
            rel='noopener noreferrer'
            className='group bg-tertiary rounded-xl px-5 py-4 flex items-center justify-between gap-3 border border-transparent hover:border-[#915EFF]/40 transition-colors duration-300'
          >
            <div className='min-w-0'>
              <p className='text-[#915EFF] text-[11px] font-semibold uppercase tracking-[0.12em]'>
                {item.platform}
              </p>
              <p className='mt-0.5 text-white text-[14px] font-medium truncate'>
                {item.handle}
              </p>
            </div>
            <ArrowUpRight className='w-4 h-4 text-secondary group-hover:text-[#915EFF] transition-colors shrink-0' />
          </a>
        ))}
      </div>
    </section>
  </PageShell>
);

export default PressPage;
