export const colors = {
  background: '#FAF6EF',
  surface: '#FFFDF8',
  textPrimary: '#2B2320',
  textSecondary: '#7A6F66',
  accent: '#C97C5D',
  success: '#8AA68A',
  destructive: '#B54A3C',
  divider: '#E8E1D6',
  cookModeBackground: '#F3EADB',
} as const;

export type ColorToken = keyof typeof colors;
