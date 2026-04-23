import { useRef, useState } from 'react';
import { Keyboard, StyleSheet, Text, TextInput, View } from 'react-native';
import { colors } from '../theme/colors';
import { radius, spacing } from '../theme/spacing';
import { fontFamilies, textStyles } from '../theme/typography';
import { newId } from '../lib/ids';
import type { Ingredient } from '../types/recipe';
import { QuantityChips } from './QuantityChips';
import { UnitChips } from './UnitChips';

type Props = {
  onAdd: (ingredient: Omit<Ingredient, 'order'>) => void;
  autoFocus?: boolean;
};

export function IngredientQuickAdd({ onAdd, autoFocus }: Props) {
  const [quantity, setQuantity] = useState('');
  const [unit, setUnit] = useState('');
  const [name, setName] = useState('');

  const qtyRef = useRef<TextInput>(null);
  const unitRef = useRef<TextInput>(null);
  const nameRef = useRef<TextInput>(null);

  const submit = () => {
    const trimmed = name.trim();
    if (!trimmed) {
      if (!quantity.trim() && !unit.trim()) {
        Keyboard.dismiss();
      } else {
        nameRef.current?.focus();
      }
      return;
    }
    onAdd({
      id: newId(),
      quantity: quantity.trim() || undefined,
      unit: unit.trim() || undefined,
      name: trimmed,
    });
    setQuantity('');
    setUnit('');
    setName('');
    qtyRef.current?.focus();
  };

  return (
    <View style={styles.wrap}>
      <View style={styles.row}>
        <View style={[styles.field, styles.qtyField]}>
          <Text style={styles.label}>Qty</Text>
          <TextInput
            ref={qtyRef}
            value={quantity}
            onChangeText={setQuantity}
            placeholder="2"
            placeholderTextColor={colors.textSecondary}
            style={styles.input}
            keyboardType="decimal-pad"
            returnKeyType="next"
            blurOnSubmit={false}
            autoFocus={autoFocus}
            onSubmitEditing={() => unitRef.current?.focus()}
          />
        </View>
        <View style={[styles.field, styles.unitField]}>
          <Text style={styles.label}>Unit</Text>
          <TextInput
            ref={unitRef}
            value={unit}
            onChangeText={setUnit}
            placeholder="cup"
            placeholderTextColor={colors.textSecondary}
            style={styles.input}
            returnKeyType="next"
            autoCapitalize="none"
            autoCorrect={false}
            blurOnSubmit={false}
            onSubmitEditing={() => nameRef.current?.focus()}
          />
        </View>
        <View style={[styles.field, styles.nameField]}>
          <Text style={styles.label}>Ingredient</Text>
          <TextInput
            ref={nameRef}
            value={name}
            onChangeText={setName}
            placeholder="flour"
            placeholderTextColor={colors.textSecondary}
            style={styles.input}
            returnKeyType="done"
            blurOnSubmit={false}
            onSubmitEditing={submit}
          />
        </View>
      </View>
      <QuantityChips value={quantity} onChange={setQuantity} />
      <UnitChips onPick={setUnit} currentValue={unit} />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    gap: spacing.sm,
  },
  row: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'flex-end',
  },
  field: {
    gap: 4,
  },
  qtyField: {
    flex: 1,
    minWidth: 56,
  },
  unitField: {
    flex: 1.2,
    minWidth: 64,
  },
  nameField: {
    flex: 3,
  },
  label: {
    fontFamily: fontFamilies.bodyMedium,
    fontSize: 11,
    lineHeight: 14,
    color: colors.textSecondary,
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    paddingLeft: 2,
  },
  input: {
    ...textStyles.body,
    color: colors.textPrimary,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.divider,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.md,
    minHeight: 44,
  },
});
