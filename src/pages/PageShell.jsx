import React from "react";
import { Link } from "react-router-dom";

import { Navbar, Footer, BackToTop } from "../components";

/**
 * Common chrome for every standalone page, so a subpage never looks
 * like a different site from the homepage.
 */
const PageShell = ({ eyebrow, title, intro, children }) => (
  <div className='relative z-0 bg-primary min-h-screen flex flex-col'>
    <div className='bg-hero-pattern bg-cover bg-no-repeat bg-center'>
      <Navbar />

      {/* Navbar is `fixed top-0` with py-5 (~76px tall), so the header
          has to clear it explicitly or the back-link collides with the logo. */}
      <header className='max-w-7xl mx-auto w-full sm:px-16 px-6 pt-28 sm:pt-32 pb-16'>
        <Link
          to='/'
          className='inline-flex items-center gap-2 text-secondary hover:text-[#915EFF] text-[14px] transition-colors duration-300'
        >
          <svg
            viewBox='0 0 24 24'
            fill='none'
            stroke='currentColor'
            strokeWidth={2}
            strokeLinecap='round'
            strokeLinejoin='round'
            className='w-4 h-4'
            aria-hidden='true'
          >
            <line x1='19' y1='12' x2='5' y2='12' />
            <polyline points='12 19 5 12 12 5' />
          </svg>
          Back to portfolio
        </Link>

        {eyebrow && (
          <p className='mt-8 sm:text-[18px] text-[14px] text-secondary uppercase tracking-wider'>
            {eyebrow}
          </p>
        )}

        <h1 className='text-white font-black md:text-[54px] sm:text-[44px] xs:text-[36px] text-[30px] leading-tight mt-2 max-w-4xl'>
          {title}
        </h1>

        {intro && (
          <p className='mt-5 text-secondary text-[17px] leading-[30px] max-w-3xl'>
            {intro}
          </p>
        )}
      </header>
    </div>

    <main className='flex-1 max-w-7xl mx-auto w-full sm:px-16 px-6 pb-24'>
      {children}
      <BackToTop />
    </main>

    <Footer />
  </div>
);

export default PageShell;
