import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Trash2 } from 'lucide-react-native';
import { colors } from '../theme/colors';
import { spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import type { Step } from '../types/recipe';

type Props = {
  step: Step;
  index: number;
  onDelete?: () => void;
};

export function StepRow({ step, index, onDelete }: Props) {
  return (
    <View style={styles.row}>
      <Text style={styles.number}>{index + 1}.</Text>
      <Text style={styles.text}>{step.text}</Text>
      {onDelete ? (
        <Pressable
          onPress={onDelete}
          accessibilityLabel={`Delete step ${index + 1}`}
          hitSlop={10}
          style={styles.deleteBtn}
        >
          <Trash2 color={colors.textSecondary} size={18} strokeWidth={2} />
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingVertical: spacing.sm,
    gap: spacing.md,
  },
  number: {
    ...textStyles.body,
    fontFamily: fontFamilies.displayBold,
    color: colors.accent,
    minWidth: 28,
    fontVariant: ['tabular-nums'],
  },
  text: {
    ...textStyles.body,
    color: colors.textPrimary,
    flex: 1,
  },
  deleteBtn: {
    padding: spacing.xs,
  },
});
