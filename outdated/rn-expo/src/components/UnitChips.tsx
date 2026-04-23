import { Pressable, ScrollView, StyleSheet, Text } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies } from '../theme/typography';

const UNITS = [
  'cup',
  'tbsp',
  'tsp',
  'oz',
  'lb',
  'g',
  'kg',
  'ml',
  'l',
  'clove',
  'pinch',
  'slice',
  'can',
  'stick',
];

type Props = {
  onPick: (value: string) => void;
  currentValue?: string;
};

export function UnitChips({ onPick, currentValue }: Props) {
  const current = currentValue?.trim().toLowerCase();
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      keyboardShouldPersistTaps="always"
      contentContainerStyle={styles.strip}
    >
      {UNITS.map((value) => {
        const active = current === value;
        return (
          <Pressable
            key={value}
            onPress={() => onPick(value)}
            style={[styles.chip, active && styles.chipActive]}
            accessibilityLabel={`Set unit to ${value}`}
          >
            <Text style={[styles.text, active && styles.textActive]}>{value}</Text>
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  strip: {
    flexDirection: 'row',
    gap: spacing.xs,
    paddingVertical: spacing.xs,
  },
  chip: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs + 2,
    borderRadius: radius.full,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.divider,
    alignItems: 'center',
    justifyContent: 'center',
  },
  chipActive: {
    backgroundColor: colors.accent,
    borderColor: colors.accent,
  },
  text: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 14,
    color: colors.textPrimary,
  },
  textActive: {
    color: '#FFFDF8',
  },
});
