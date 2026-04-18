import Svg, { Circle, Ellipse, Path, Rect } from 'react-native-svg';
import { colors } from '../theme/colors';

type Props = {
  size?: number;
  color?: string;
};

export function LlamaMascot({ size = 120, color = colors.accent }: Props) {
  return (
    <Svg width={size} height={size} viewBox="0 0 120 120" fill="none">
      <Ellipse cx="60" cy="92" rx="28" ry="18" fill={color} opacity={0.15} />
      <Rect
        x="44"
        y="52"
        width="32"
        height="42"
        rx="14"
        fill={color}
        opacity={0.9}
      />
      <Rect
        x="52"
        y="20"
        width="18"
        height="42"
        rx="8"
        fill={color}
      />
      <Path
        d="M48 26 L52 12 L56 26 Z"
        fill={color}
      />
      <Path
        d="M66 26 L70 12 L74 26 Z"
        fill={color}
      />
      <Circle cx="57" cy="36" r="2.2" fill={colors.textPrimary} />
      <Circle cx="65" cy="36" r="2.2" fill={colors.textPrimary} />
      <Path
        d="M57 44 Q61 47 65 44"
        stroke={colors.textPrimary}
        strokeWidth={1.8}
        strokeLinecap="round"
        fill="none"
      />
      <Rect x="49" y="92" width="6" height="12" rx="2" fill={color} />
      <Rect x="65" y="92" width="6" height="12" rx="2" fill={color} />
    </Svg>
  );
}
