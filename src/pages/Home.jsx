import React from "react";

import {
  Contact,
  Experience,
  Feedbacks,
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
  Gallery,
} from "../components";

const Home = () => (
  <div className='relative z-0 bg-primary'>
    <div className='bg-hero-pattern bg-cover bg-no-repeat bg-center'>
      <Navbar />
      <Hero />
    </div>

    <Experience />
    <Tech />
    <Works />
    <Research />
    <Thoughts />
    <Press />
    <Feedbacks />
    <CertificateWall />
    <Gallery />

    <div className='relative z-0'>
      <Contact />
      <StarsCanvas />
    </div>

    <Footer />
  </div>
);

export default Home;
