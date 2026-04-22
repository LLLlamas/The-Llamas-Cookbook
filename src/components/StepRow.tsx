import { useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { Check, Trash2, X } from 'lucide-react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import type { Step } from '../types/recipe';

type Props = {
  step: Step;
  index: number;
  onDelete?: () => void;
  onUpdate?: (patch: Pick<Step, 'text'>) => void;
};

export function StepRow({ step, index, onDelete, onUpdate }: Props) {
  const [isEditing, setIsEditing] = useState(false);
  const [text, setText] = useState(step.text);
  const inputRef = useRef<TextInput>(null);

  const enterEdit = () => {
    if (!onUpdate) return;
    setText(step.text);
    setIsEditing(true);
  };

  const cancel = () => {
    setText(step.text);
    setIsEditing(false);
  };

  const save = () => {
    const trimmed = text.trim();
    if (!trimmed || !onUpdate) {
      cancel();
      return;
    }
    onUpdate({ text: trimmed });
    setIsEditing(false);
  };

  if (isEditing) {
    return (
      <View style={styles.editWrap}>
        <View style={styles.editRow}>
          <View style={styles.numberBadge}>
            <Text style={styles.numberBadgeText}>{index + 1}</Text>
          </View>
          <TextInput
            ref={inputRef}
            value={text}
            onChangeText={setText}
            placeholder={`Step ${index + 1}`}
            placeholderTextColor={colors.textSecondary}
            style={styles.input}
            multiline
            autoFocus
            returnKeyType="done"
            blurOnSubmit={false}
            onSubmitEditing={save}
          />
        </View>
        <View style={styles.actions}>
          <Pressable
            onPress={cancel}
            style={[styles.actionBtn, styles.cancelBtn]}
            accessibilityLabel="Cancel edit"
          >
            <X size={18} color={colors.textSecondary} strokeWidth={2.25} />
            <Text style={styles.cancelText}>Cancel</Text>
          </Pressable>
          <Pressable
            onPress={save}
            style={[styles.actionBtn, styles.saveBtn]}
            accessibilityLabel="Save step"
          >
            <Check size={18} color="#FFFDF8" strokeWidth={2.5} />
            <Text style={styles.saveText}>Save</Text>
          </Pressable>
        </View>
      </View>
    );
  }

  return (
    <Pressable
      onPress={onUpdate ? enterEdit : undefined}
      style={({ pressed }) => [
        styles.row,
        onUpdate && pressed && styles.rowPressed,
      ]}
      accessibilityLabel={onUpdate ? `Edit step ${index + 1}` : undefined}
    >
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
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.xs,
    gap: spacing.md,
    borderRadius: radius.sm,
  },
  rowPressed: {
    backgroundColor: colors.divider,
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
  editWrap: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: spacing.sm,
    borderWidth: 1,
    borderColor: colors.accent,
    gap: spacing.sm,
  },
  editRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.sm,
  },
  numberBadge: {
    width: 36,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.background,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  numberBadgeText: {
    fontFamily: fontFamilies.displayBold,
    fontSize: 16,
    color: colors.accent,
    fontVariant: ['tabular-nums'],
  },
  input: {
    ...textStyles.body,
    flex: 1,
    color: colors.textPrimary,
    backgroundColor: colors.background,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.md,
    minHeight: 44,
    textAlignVertical: 'top',
  },
  actions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.sm,
  },
  actionBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.md,
  },
  cancelBtn: {
    backgroundColor: colors.background,
    borderWidth: 1,
    borderColor: colors.divider,
  },
  cancelText: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 14,
    color: colors.textSecondary,
  },
  saveBtn: {
    backgroundColor: colors.accent,
  },
  saveText: {
    fontFamily: fontFamilies.bodySemibold,
    fontSize: 14,
    color: '#FFFDF8',
  },
});
