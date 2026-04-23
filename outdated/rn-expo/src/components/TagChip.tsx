import { Pressable, StyleSheet, Text, View } from 'react-native';
import { X } from 'lucide-react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies } from '../theme/typography';

type Props = {
  label: string;
  onRemove?: () => void;
  tone?: 'default' | 'accent';
};

const capitalize = (s: string) =>
  s.length === 0 ? s : s[0].toUpperCase() + s.slice(1);

export function TagChip({ label, onRemove, tone = 'default' }: Props) {
  const chipStyle = tone === 'accent' ? styles.chipAccent : styles.chip;
  const textStyle = tone === 'accent' ? styles.textAccent : styles.text;
  return (
    <View style={[styles.base, chipStyle]}>
      <Text style={textStyle}>{capitalize(label)}</Text>
      {onRemove ? (
        <Pressable
          onPress={onRemove}
          accessibilityLabel={`Remove tag ${label}`}
          hitSlop={8}
        >
          <X size={14} color={tone === 'accent' ? '#FFFDF8' : colors.textSecondary} strokeWidth={2.5} />
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  base: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs + 2,
    borderRadius: radius.full,
  },
  chip: {
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  chipAccent: {
    backgroundColor: colors.accent,
  },
  text: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 13,
    color: colors.textPrimary,
  },
  textAccent: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 13,
    color: '#FFFDF8',
  },
});
