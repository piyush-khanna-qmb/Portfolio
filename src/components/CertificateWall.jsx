import React, { useState } from "react";
import { motion } from "framer-motion";

import { styles } from "../styles";
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
      <motion.div variants={textVariant()}>
        <p className={styles.sectionSubText}>Things I picked up along the way</p>
        <h2 className={styles.sectionHeadText}>The Wall.</h2>
      </motion.div>

      <motion.p
        variants={fadeIn("", "", 0.1, 1)}
        className='mt-3 text-secondary text-[17px] max-w-3xl leading-[30px]'
      >
        Certifications, contests and the occasional world record. Click any
        frame to read why it is on the wall.
      </motion.p>

      <div className='mt-14 grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-6 sm:gap-8'>
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
