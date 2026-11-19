export { useMobileTokens, useReducedMotion, useLogoAvatarClock } from "./pose.js";
export const useAvatarOnScreen = () => true,
  useId = () => "bot",
  useMemo = (create) => create();
import { useLogoAvatarClock } from "./pose.js";
export function useDerivedValue(compute) {
  const clock = useLogoAvatarClock();
  let previous, result;
  return {
    get value() {
      if (previous !== clock.value) {
        previous = clock.value;
        result = compute();
      }
      return result;
    },
  };
}
export const useAnimatedProps = (compute) => compute;
export const usePoke = () => {},
  useEffect = () => {},
  cancelAnimation = () => {},
  useAnimatedStyle = () => {},
  useSharedValue = (value) => ({ value });
export const Defs = "defs",
  ClipPath = "clipPath",
  Ellipse = "ellipse",
  G = "g",
  LinearGradient = "linearGradient",
  Mask = "mask",
  Path = "path",
  RadialGradient = "radialGradient",
  Rect = "rect",
  Stop = "stop",
  Pressable = "g";
