import React, { useState } from "react";
import { motion } from "framer-motion";

import { brickWall } from "../assets";
import { certificates } from "../constants";
import { SectionWrapper } from "../hoc";
import { fadeIn, textVariant } from "../utils/motion";
import Lightbox from "./Lightbox";

const FramedCertificate = ({ index, certificate, onOpen }) => (
  <motion.button
    type='button'
    variants={fadeIn("up", "spring", (index % 4) * 0.12, 0.7)}
    onClick={() => onOpen(certificate)}
    aria-label={`View certificate: ${certificate.title}`}
    className='group text-left w-full focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF] rounded-sm'
  >
    <div className='wood-frame rounded-sm p-[10px] sm:p-[14px] transition-transform duration-300 group-hover:-translate-y-1.5'>
      {/* Mat board: the cream border a real frame has between wood and print */}
      <div className='wood-frame-inner bg-[#f2ece1] p-[7px] sm:p-[9px] rounded-[2px]'>
        <div className='bg-white aspect-[4/3] overflow-hidden'>
          <img
            src={certificate.image}
            alt={certificate.title}
            loading='lazy'
            className='w-full h-full object-contain'
          />
        </div>
      </div>
    </div>

    <div className='mt-3 px-1'>
      <h3 className='text-white text-[14px] font-semibold leading-snug group-hover:text-[#915EFF] transition-colors'>
        {certificate.title}
      </h3>
      <p className='mt-0.5 text-secondary text-[12px] leading-snug'>
        {certificate.issuer}
        {certificate.date ? ` · ${certificate.date}` : ""}
      </p>
    </div>
  </motion.button>
);

const CertificateWall = () => {
  const [active, setActive] = useState(null);

  return (
    <>
      {/* Brick backdrop. Breaks out of the section's max-width to run the
          full viewport, sits behind the content, and is heavily darkened
          so it reads as a dim wall rather than competing with the frames.
          Gradients at the top and bottom fade it into the sections above
          and below instead of ending on a hard line. */}
      <div
        aria-hidden='true'
        className='pointer-events-none absolute inset-y-0 left-1/2 -translate-x-1/2 w-screen -z-10 overflow-hidden'
      >
        <div
          className='absolute inset-0 opacity-[0.22]'
          style={{
            backgroundImage: `url(${brickWall})`,
            backgroundSize: "520px auto",
            backgroundRepeat: "repeat",
          }}
        />
        <div className='absolute inset-0 bg-primary/55' />
        <div className='absolute inset-x-0 top-0 h-40 bg-gradient-to-b from-primary to-transparent' />
        <div className='absolute inset-x-0 bottom-0 h-40 bg-gradient-to-t from-primary to-transparent' />
      </div>

      {/* Set like the sleeve: chalk capitals, a rule under the name, and a
          second rule under the title. Kept to two lines rather than the
          sleeve's five so it works as a section heading. */}
      <motion.div variants={textVariant()}>
        {/* Each line is wrapped in its own w-fit block so the rule beneath
            it shrinks to that line's width instead of the heading's. */}
        <h2 className='font-offwall'>
          <span className='block w-fit'>
            <span className='block text-[13px] sm:text-[16px] uppercase tracking-[0.06em] leading-[1.5]'>
              Piyush Khanna
            </span>
            <span className='chalk-rule block mt-1.5' />
          </span>

          <span className='relative group block w-fit mt-3'>
            <span
              tabIndex={0}
              className='block text-[24px] xs:text-[30px] sm:text-[42px] md:text-[50px] uppercase leading-[1.2] cursor-help focus:outline-none'
            >
              Off the Wall
            </span>

            {/* Inline font/colour/shadow because `.font-offwall *` sets all
                three on every descendant, which would otherwise render this
                tooltip in chalk. */}
            <span
              role='tooltip'
              style={{
                fontFamily: '"Poppins", sans-serif',
                color: "#fff",
                textShadow: "none",
              }}
              className='pointer-events-none absolute left-full top-1/2 -translate-y-1/2 ml-5 whitespace-nowrap rounded-md bg-tertiary px-3 py-2 text-[13px] font-normal leading-[1.4] normal-case tracking-normal opacity-0 shadow-lg transition-opacity duration-200 group-hover:opacity-100 group-focus-within:opacity-100 z-20'
            >
              &apos;Cos I was listening to this while creating this site
              <span
                aria-hidden='true'
                className='absolute right-full top-1/2 -translate-y-1/2 -mr-1 w-2 h-2 rotate-45 bg-tertiary'
              />
            </span>
          </span>
        </h2>
      </motion.div>

      <motion.p
        variants={fadeIn("", "", 0.1, 1)}
        className='mt-3 text-secondary text-[17px] max-w-3xl leading-[30px]'
      >
        Certifications, contests and the occasional world record. Things I
        picked up along the way. Click any frame to read why it is on the wall.
      </motion.p>

      <div className='mt-12 grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-6 sm:gap-8'>
        {certificates.map((certificate, index) => (
          <FramedCertificate
            key={certificate.title}
            index={index}
            certificate={certificate}
            onOpen={setActive}
          />
        ))}
      </div>

      <Lightbox item={active} onClose={() => setActive(null)} />
    </>
  );
};

export default SectionWrapper(CertificateWall, "certificates");
