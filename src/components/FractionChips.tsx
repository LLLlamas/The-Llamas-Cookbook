import { Pressable, ScrollView, StyleSheet, Text } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies } from '../theme/typography';

const FRACTIONS = ['1/4', '1/3', '1/2', '2/3', '3/4', '1', '1 1/2', '2', '3', '4'];

type Props = {
  onPick: (value: string) => void;
  currentValue?: string;
};

export function FractionChips({ onPick, currentValue }: Props) {
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      keyboardShouldPersistTaps="always"
      contentContainerStyle={styles.strip}
    >
      {FRACTIONS.map((value) => {
        const active = currentValue?.trim() === value;
        return (
          <Pressable
            key={value}
            onPress={() => onPick(value)}
            style={[styles.chip, active && styles.chipActive]}
            accessibilityLabel={`Set quantity to ${value}`}
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
    minWidth: 44,
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
    fontVariant: ['tabular-nums'],
  },
  textActive: {
    color: '#FFFDF8',
  },
});
