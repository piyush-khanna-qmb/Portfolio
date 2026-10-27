import { motion } from "framer-motion";

import { styles } from "../styles";
import { ComputersCanvas } from "./canvas";

const Hero = () => {
  return (
    <section className={`relative w-full h-screen mx-auto`}>
      <div
        className={`absolute inset-0 top-[90px] sm:top-[120px] max-w-7xl mx-auto ${styles.paddingX} flex flex-row items-start gap-5`}
      >
        <div className='flex flex-col justify-center items-center mt-5'>
          <div className='w-5 h-5 rounded-full bg-[#915EFF]' />
          <div className='w-1 sm:h-80 h-40 violet-gradient' />
        </div>

        <div>
          <h1 className={`${styles.heroHeadText} text-white`}>
            Hi, I'm <span className='text-[#915EFF]'>Piyush</span>
          </h1>
          <p className={`${styles.heroSubText} mt-2 text-white-100`}>
            I specialise in <br className='sm:block hidden' />
            IoT, Web Development and Robotics
          </p>

          {/* TODO: add the real file at public/resume.pdf — placeholder until Piyush supplies it */}
          <a
            href='resume.pdf'
            download
            className='mt-4 sm:mt-6 bg-[#915EFF]/60 py-2 sm:py-3 px-5 sm:px-8 rounded-lg sm:rounded-xl outline-none w-fit text-white font-medium sm:font-bold text-sm sm:text-base shadow-[0_0_25px_rgba(145,94,255,0.45)] hover:shadow-[0_0_35px_rgba(145,94,255,0.7)] transition-shadow duration-300 flex items-center gap-1.5 sm:gap-2'
          >
            <svg
              xmlns='http://www.w3.org/2000/svg'
              className='w-4 h-4 sm:w-5 sm:h-5'
              fill='none'
              viewBox='0 0 24 24'
              stroke='currentColor'
              strokeWidth={2}
            >
              <path
                strokeLinecap='round'
                strokeLinejoin='round'
                d='M12 3v12m0 0l-4-4m4 4l4-4M4 21h16'
              />
            </svg>
            Download Resume
          </a>
        </div>
      </div>

      <ComputersCanvas />

      <div className='absolute xs:bottom-10 bottom-32 w-full flex justify-center items-center'>
        <a href='#about'>
          <div className='w-[35px] h-[64px] rounded-3xl border-4 border-secondary flex justify-center items-start p-2'>
            <motion.div
              animate={{
                y: [0, 24, 0],
              }}
              transition={{
                duration: 1.5,
                repeat: Infinity,
                repeatType: "loop",
              }}
              className='w-3 h-3 rounded-full bg-secondary mb-1'
            />
          </div>
        </a>
      </div>
    </section>
  );
};

export default Hero;
