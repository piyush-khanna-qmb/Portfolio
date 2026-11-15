import React, { Suspense } from "react";
import { Canvas } from "@react-three/fiber";
import { OrbitControls, Preload, useGLTF } from "@react-three/drei";

import CanvasLoader from "../Loader";
import useInView from "../../hooks/useInView";
import useIsMobile from "../../hooks/useIsMobile";
import useGLRecovery from "../../hooks/useGLRecovery";

const Earth = () => {
  const earth = useGLTF("./planet/scene.gltf");

  return (
    <primitive object={earth.scene} scale={2.5} position-y={0} rotation-y={0} />
  );
};

const EarthCanvas = () => {
  const isMobile = useIsMobile();
  const [ref, inView] = useInView();
  const { glKey, onCreated } = useGLRecovery();

  return (
    <div ref={ref} className='w-full h-full'>
      {inView && (
        <Canvas
          key={glKey}
          onCreated={onCreated}
          frameloop='demand'
          dpr={isMobile ? 1 : [1, 2]}
          camera={{
            fov: 45,
            near: 0.1,
            far: 200,
            position: [-4, 3, 6],
          }}
        >
          <Suspense fallback={<CanvasLoader />}>
            <OrbitControls
              autoRotate
              enableZoom={false}
              maxPolarAngle={Math.PI / 2}
              minPolarAngle={Math.PI / 2}
            />
            <Earth />

            <Preload all />
          </Suspense>
        </Canvas>
      )}
    </div>
  );
};

export default EarthCanvas;
