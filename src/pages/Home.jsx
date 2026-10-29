import React from "react";

import {
  Contact,
  Experience,
  Hero,
  Navbar,
  Tech,
  Works,
  StarsCanvas,
  Footer,
  Press,
  Thoughts,
  Research,
  CertificateWall,
} from "../components";
import SEO from "../components/SEO";

const Home = () => (
  /* overflow-x:clip contains the certificate wall's full-bleed brick layer,
     which is 100vw and so overshoots by the scrollbar width. `clip` rather
     than `hidden` because hidden would create a scroll container and can
     clip the fixed navbar. */
  <div className='relative z-0 bg-primary [overflow-x:clip]'>
    <SEO
      title='Piyush Khanna — Software & Applied AI Engineer, Robotics'
      description='Portfolio of Piyush Khanna: software and applied AI engineer specialising in IoT, harness engineering, and robotics. Founder of Emperia Smart Solutions. Projects, press, and writing.'
      path='/'
    />
    <div className='bg-hero-pattern bg-cover bg-no-repeat bg-center'>
      <Navbar />
      <Hero />
    </div>

    <Experience />
    <Tech />
    <Works />
    <Research />
    <Thoughts />
    <CertificateWall />
    <Press />

    <div className='relative z-0'>
      <Contact />
      <StarsCanvas />
    </div>

    <Footer />
  </div>
);

export default Home;
