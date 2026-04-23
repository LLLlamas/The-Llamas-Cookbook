import type { TextStyle } from 'react-native';

export const fontFamilies = {
  displayMedium: 'Fraunces_500Medium',
  display: 'Fraunces_600SemiBold',
  displayBold: 'Fraunces_700Bold',
  body: 'Inter_400Regular',
  bodyMedium: 'Inter_500Medium',
  bodySemibold: 'Inter_600SemiBold',
} as const;

export const textStyles = {
  recipeTitle: {
    fontFamily: fontFamilies.display,
    fontSize: 28,
    lineHeight: 34,
  },
  sectionHeading: {
    fontFamily: fontFamilies.display,
    fontSize: 18,
    lineHeight: 24,
  },
  body: {
    fontFamily: fontFamilies.body,
    fontSize: 16,
    lineHeight: 24,
  },
  ingredient: {
    fontFamily: fontFamilies.body,
    fontSize: 17,
    lineHeight: 26,
  },
  ingredientCook: {
    fontFamily: fontFamilies.body,
    fontSize: 20,
    lineHeight: 30,
  },
  caption: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 13,
    lineHeight: 18,
  },
} satisfies Record<string, TextStyle>;
