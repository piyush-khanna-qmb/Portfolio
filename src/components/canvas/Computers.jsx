import React, { Suspense, useEffect, useState } from "react";
import { Canvas } from "@react-three/fiber";
import { OrbitControls, Preload, useGLTF } from "@react-three/drei";

import CanvasLoader from "../Loader";
import useInView from "../../hooks/useInView";
import useIsMobile from "../../hooks/useIsMobile";
import useGLRecovery from "../../hooks/useGLRecovery";

const Computers = ({ isMobile }) => {
  const computer = useGLTF("./desktop_pc/scene.gltf");

  return (
    <mesh>
      <hemisphereLight intensity={0.15} groundColor='black' />
      <spotLight
        position={[-20, 50, 10]}
        angle={0.12}
        penumbra={1}
        intensity={1}
        /* Shadow maps are a real GPU memory cost, and mobile GPUs are the
           ones already fighting for headroom, so they lose this one. */
        castShadow={!isMobile}
        shadow-mapSize={1024}
      />
      <pointLight intensity={1} />
      <primitive
        object={computer.scene}
        scale={isMobile ? 0.45 : 0.75}
        /* Desktop sits the machine slightly right of centre so it clears
           the hero copy. Screen-right for a camera at [20, 3, 5] is
           roughly +x / -z, hence both values moving together.
           Mobile is smaller now, so it is lifted to stay optically centred. */
        position={isMobile ? [0, -2.4, -1.6] : [0.2, -3.25, -2.2]}
        rotation={[-0.01, -0.2, -0.1]}
      />
    </mesh>
  );
};

const ComputersCanvas = () => {
  const isMobile = useIsMobile();
  const [reducedMotion, setReducedMotion] = useState(false);
  const [ref, inView] = useInView();
  const { glKey, onCreated } = useGLRecovery();

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReducedMotion(mq.matches);
    const onChange = (e) => setReducedMotion(e.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  return (
    <div ref={ref} className='w-full h-full'>
      {inView && (
        <Canvas
          key={glKey}
          onCreated={onCreated}
          /* The drift needs a continuous loop. Under frameloop="demand" the
             canvas only paints when something invalidates it, so autoRotate
             would advance its target and never render. Anyone who prefers
             reduced motion keeps the cheaper on-demand behaviour. */
          frameloop={reducedMotion ? "demand" : "always"}
          shadows={!isMobile}
          dpr={isMobile ? 1 : [1, 2]}
          camera={{ position: [20, 3, 5], fov: 25 }}
        >
          <Suspense fallback={<CanvasLoader />}>
            <OrbitControls
              enableZoom={false}
              maxPolarAngle={Math.PI / 2}
              minPolarAngle={Math.PI / 2}
              /* Slow idle spin so it reads as three-dimensional without
                 demanding attention. Roughly one turn every 85 seconds.
                 Dragging takes over, then the drift resumes. */
              autoRotate={!reducedMotion}
              autoRotateSpeed={0.7}
            />
            <Computers isMobile={isMobile} />
          </Suspense>

          <Preload all />
        </Canvas>
      )}
    </div>
  );
};

export default ComputersCanvas;
