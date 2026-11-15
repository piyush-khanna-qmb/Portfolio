import React from "react";

import { BallCanvas } from "./canvas";
import { SectionWrapper } from "../hoc";
import { technologies } from "../constants";
import useIsMobile from "../hooks/useIsMobile";

const Tech = () => {
  /* The 3D balls are the single heaviest thing on the page on phones —
     8 concurrent WebGL contexts each loading a decal texture. Flat icons
     on mobile avoid that entirely instead of trying to tune it further. */
  const isMobile = useIsMobile();

  return (
    <div className='flex flex-row flex-wrap justify-center gap-10'>
      {technologies.map((technology) => (
        <div className='w-28 h-28' key={technology.name}>
          {isMobile ? (
            <div className='w-full h-full rounded-full bg-tertiary flex items-center justify-center p-6'>
              <img
                src={technology.icon}
                alt={technology.name}
                className='w-full h-full object-contain'
              />
            </div>
          ) : (
            <BallCanvas icon={technology.icon} />
          )}
        </div>
      ))}
    </div>
  );
};

export default SectionWrapper(Tech, "");
