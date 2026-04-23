import { useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { Check, Trash2, X } from 'lucide-react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import type { Ingredient } from '../types/recipe';
import { QuantityChips } from './QuantityChips';
import { UnitChips } from './UnitChips';

type Props = {
  ingredient: Ingredient;
  onDelete?: () => void;
  onUpdate?: (patch: Pick<Ingredient, 'quantity' | 'unit' | 'name'>) => void;
};

export function IngredientRow({ ingredient, onDelete, onUpdate }: Props) {
  const [isEditing, setIsEditing] = useState(false);
  const [quantity, setQuantity] = useState(ingredient.quantity ?? '');
  const [unit, setUnit] = useState(ingredient.unit ?? '');
  const [name, setName] = useState(ingredient.name);

  const qtyRef = useRef<TextInput>(null);
  const unitRef = useRef<TextInput>(null);
  const nameRef = useRef<TextInput>(null);

  const enterEdit = () => {
    if (!onUpdate) return;
    setQuantity(ingredient.quantity ?? '');
    setUnit(ingredient.unit ?? '');
    setName(ingredient.name);
    setIsEditing(true);
  };

  const cancel = () => {
    setQuantity(ingredient.quantity ?? '');
    setUnit(ingredient.unit ?? '');
    setName(ingredient.name);
    setIsEditing(false);
  };

  const save = () => {
    const trimmed = name.trim();
    if (!trimmed || !onUpdate) {
      cancel();
      return;
    }
    onUpdate({
      quantity: quantity.trim() || undefined,
      unit: unit.trim() || undefined,
      name: trimmed,
    });
    setIsEditing(false);
  };

  if (isEditing) {
    return (
      <View style={styles.editWrap}>
        <View style={styles.inputRow}>
          <TextInput
            ref={qtyRef}
            value={quantity}
            onChangeText={setQuantity}
            placeholder="Qty"
            placeholderTextColor={colors.textSecondary}
            style={[styles.input, styles.qtyInput]}
            keyboardType="decimal-pad"
            returnKeyType="next"
            blurOnSubmit={false}
            autoFocus
            onSubmitEditing={() => unitRef.current?.focus()}
          />
          <TextInput
            ref={unitRef}
            value={unit}
            onChangeText={setUnit}
            placeholder="Unit"
            placeholderTextColor={colors.textSecondary}
            style={[styles.input, styles.unitInput]}
            returnKeyType="next"
            autoCapitalize="none"
            autoCorrect={false}
            blurOnSubmit={false}
            onSubmitEditing={() => nameRef.current?.focus()}
          />
          <TextInput
            ref={nameRef}
            value={name}
            onChangeText={setName}
            placeholder="Ingredient"
            placeholderTextColor={colors.textSecondary}
            style={[styles.input, styles.nameInput]}
            returnKeyType="done"
            blurOnSubmit={false}
            onSubmitEditing={save}
          />
        </View>
        <QuantityChips value={quantity} onChange={setQuantity} />
        <UnitChips onPick={setUnit} currentValue={unit} />
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
            accessibilityLabel="Save ingredient"
          >
            <Check size={18} color="#FFFDF8" strokeWidth={2.5} />
            <Text style={styles.saveText}>Save</Text>
          </Pressable>
        </View>
      </View>
    );
  }

  const qty = ingredient.quantity?.trim();
  const unitLabel = ingredient.unit?.trim();

  return (
    <Pressable
      onPress={onUpdate ? enterEdit : undefined}
      style={({ pressed }) => [
        styles.row,
        onUpdate && pressed && styles.rowPressed,
      ]}
      accessibilityLabel={onUpdate ? `Edit ${ingredient.name}` : undefined}
    >
      <View style={styles.qtyBlock}>
        {qty ? <Text style={styles.qty}>{qty}</Text> : null}
        {unitLabel ? <Text style={styles.unit}>{unitLabel}</Text> : null}
      </View>
      <Text style={styles.nameText}>{ingredient.name}</Text>
      {onDelete ? (
        <Pressable
          onPress={onDelete}
          accessibilityLabel={`Delete ${ingredient.name}`}
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
    alignItems: 'center',
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.xs,
    gap: spacing.md,
    borderRadius: radius.sm,
  },
  rowPressed: {
    backgroundColor: colors.divider,
  },
  qtyBlock: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: 4,
    minWidth: 72,
  },
  qty: {
    ...textStyles.ingredient,
    fontFamily: fontFamilies.bodySemibold,
    color: colors.textPrimary,
    fontVariant: ['tabular-nums'],
  },
  unit: {
    ...textStyles.caption,
    color: colors.textSecondary,
  },
  nameText: {
    ...textStyles.ingredient,
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
    gap: spacing.xs,
  },
  inputRow: {
    flexDirection: 'row',
    gap: spacing.sm,
  },
  input: {
    ...textStyles.body,
    color: colors.textPrimary,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.sm,
    backgroundColor: colors.background,
    borderRadius: radius.sm,
  },
  qtyInput: {
    flex: 1,
    minWidth: 44,
  },
  unitInput: {
    flex: 1.2,
    minWidth: 56,
  },
  nameInput: {
    flex: 3,
  },
  actions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.sm,
    marginTop: spacing.xs,
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
