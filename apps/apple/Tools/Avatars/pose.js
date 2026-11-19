let pose;
export function setPose(value) {
  pose = value;
}
export const useMobileTokens = () => pose.tokens;
export const useReducedMotion = () => pose.still;
export const useLogoAvatarClock = () => pose.clock;
