import React from "react";

/**
 * Live trigger graphics for the Omni prompt showcase.
 *
 * All five share one circular frame so a column of them reads as a
 * family rather than a pile of unrelated illustrations. The motion is
 * CSS (see index.css) and stops under prefers-reduced-motion.
 */
const Pin = () => (
  <svg
    viewBox='0 0 24 24'
    fill='none'
    stroke='currentColor'
    strokeWidth={1.7}
    strokeLinecap='round'
    strokeLinejoin='round'
    className='w-[42%] h-[42%] relative z-10 text-[#915EFF]'
    aria-hidden='true'
  >
    <path d='M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z' />
    <circle cx='12' cy='10' r='3' />
  </svg>
);

const SPEEDS = [
  ["0", 21, 42],
  ["60", 50, 21],
  ["120", 79, 42],
];

const RAYS = [0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330];

const TriggerViz = ({ kind, className = "w-[74px] h-[74px]" }) => {
  const frame = `viz-frame shrink-0 ${className}`;

  if (kind === "radar") {
    return (
      <div aria-hidden='true' className={`${frame} viz-radar`}>
        <span className='viz-blip' />
      </div>
    );
  }

  if (kind === "pin") {
    return (
      <div aria-hidden='true' className={frame}>
        <span className='viz-ring' />
        <span className='viz-ring' />
        <span className='viz-ring' />
        <Pin />
      </div>
    );
  }

  if (kind === "apps") {
    return (
      <div aria-hidden='true' className={frame}>
        <div className='grid grid-cols-3 gap-[5px] w-[58%] h-[58%]'>
          {Array.from({ length: 9 }).map((_, i) => (
            <span
              key={i}
              className={`viz-cell ${i === 4 ? "viz-cell-active" : ""}`}
            />
          ))}
        </div>
      </div>
    );
  }

  if (kind === "clock") {
    return (
      <div aria-hidden='true' className={frame}>
        <span className='absolute inset-[22%] rounded-full border border-[#915EFF]/25' />
        <span className='viz-hand' />
        <span className='w-1.5 h-1.5 rounded-full bg-[#915EFF] relative z-10' />
      </div>
    );
  }

  if (kind === "sunrise") {
    return (
      <div aria-hidden='true' className={frame}>
        <span className='viz-sunwrap'>
          <svg viewBox='0 0 100 100' className='viz-sun-svg' fill='none'>
            <circle
              className='viz-sun-disc'
              cx='50'
              cy='50'
              r='16'
              stroke='currentColor'
              strokeWidth={2.2}
            />
            {RAYS.map((angle) => (
              <line
                key={angle}
                className='viz-ray'
                x1='50'
                y1='25'
                x2='50'
                y2='4'
                stroke='currentColor'
                strokeWidth={2.2}
                strokeLinecap='round'
                strokeDasharray='21 21'
                style={{ transform: `rotate(${angle}deg)` }}
              />
            ))}
          </svg>
        </span>
        <span className='viz-ground' />
        <span className='viz-horizon' />
      </div>
    );
  }

  if (kind === "night") {
    return (
      <div aria-hidden='true' className={frame}>
        <span className='viz-star' style={{ top: "26%", left: "30%" }} />
        <span className='viz-star' style={{ top: "62%", left: "24%", animationDelay: "0.9s" }} />
        <span className='viz-star' style={{ top: "34%", left: "70%", animationDelay: "1.7s" }} />
        <span className='viz-star' style={{ top: "70%", left: "66%", animationDelay: "2.4s" }} />
        <svg
          viewBox='0 0 24 24'
          fill='none'
          stroke='currentColor'
          strokeWidth={1.6}
          strokeLinecap='round'
          strokeLinejoin='round'
          className='w-[38%] h-[38%] relative z-10 text-[#915EFF]'
        >
          <path d='M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z' />
        </svg>
      </div>
    );
  }

  /* level: the volume bar sitting in the bowl of a speed gauge */
  return (
    <div aria-hidden='true' className={frame}>
      <svg viewBox='0 0 100 100' className='viz-gauge' fill='none'>
        {/* arc track, then the fill that rides up it with the needle */}
        <path
          d='M 8 50 A 42 42 0 0 1 92 50'
          stroke='currentColor'
          strokeOpacity='0.22'
          strokeWidth={4}
          strokeLinecap='round'
        />
        <path
          className='viz-arc-fill'
          d='M 8 50 A 42 42 0 0 1 92 50'
          stroke='currentColor'
          strokeWidth={4}
          strokeLinecap='round'
        />

        {/* enough of a scale to read the needle against, without the
            tick marks that made it busy */}
        {SPEEDS.map(([label, x, y]) => (
          <text
            key={label}
            x={x}
            y={y}
            fill='currentColor'
            fillOpacity='0.5'
            fontSize='9'
            fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
            textAnchor='middle'
            dominantBaseline='middle'
          >
            {label}
          </text>
        ))}
        <text
          x='50'
          y='36'
          fill='currentColor'
          fillOpacity='0.32'
          fontSize='6.5'
          fontFamily='ui-monospace, SFMono-Regular, Menlo, monospace'
          textAnchor='middle'
        >
          km/h
        </text>

        {/* the marker itself: a short radial segment straddling the arc,
            travelling along it rather than pivoting from the hub */}
        <line
          className='viz-needle'
          x1='50'
          y1='14'
          x2='50'
          y2='4'
          stroke='#c9b0ff'
          strokeWidth={3.4}
          strokeLinecap='round'
        />

        {/* volume, in the space the hinged pointer used to occupy */}
        <line
          x1='50'
          y1='92'
          x2='50'
          y2='58'
          stroke='currentColor'
          strokeOpacity='0.14'
          strokeWidth={11}
          strokeLinecap='round'
        />
        <line
          className='viz-vlevel'
          x1='50'
          y1='92'
          x2='50'
          y2='58'
          stroke='currentColor'
          strokeWidth={11}
          strokeLinecap='round'
        />
      </svg>
    </div>
  );
};

export default TriggerViz;
