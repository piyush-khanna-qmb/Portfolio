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
import { homeJsonLd } from "../constants/seo";

const Home = () => (
  /* overflow-x:clip contains the certificate wall's full-bleed brick layer,
     which is 100vw and so overshoots by the scrollbar width. `clip` rather
     than `hidden` because hidden would create a scroll container and can
     clip the fixed navbar. */
  <div className='relative z-0 bg-primary [overflow-x:clip]'>
    <SEO
      title='Piyush Khanna — Creator of Anushka Humanoid Robot | Software & Applied AI Engineer'
      description="Piyush Khanna, creator of Anushka, India's humanoid robot. Software and applied AI engineer in IoT and robotics. Projects, press, and writing."
      path='/'
      jsonLd={homeJsonLd}
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
